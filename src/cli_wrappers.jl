using ArgParse
using DataFrames
using Distributed
using ProgressMeter
using Statistics

import CSV

function parse_commandline(args::Union{Nothing, Array{String, 1}}=nothing)
    s = ArgParseSettings()
    @add_arg_table s begin
        "--x", "-x" # REPEAT IN JSON
            help = "name of x column"
            default = "x"
        "--y", "-y" # REPEAT IN JSON
            help = "name of gene column"
            default = "y"
        "--gene" # REPEAT IN JSON
            help = "name of gene column"
            default = "gene"

        "--iters", "-i"
            help = "Number of iterations"
            arg_type = Int
            default = 100
        "--refinement-iters" # TO JSON
            help = "Number of iterations for refinement of results"
            arg_type = Int
            default = 50
        "--min-molecules-per-gene" # TO JSON
            help = "Minimal number of molecules per gene"
            arg_type = Int
            default = 1
        "--min-molecules-per-cell" # TO JSON
            help = "Minimal number of molecules for a cell to be considered as real"
            arg_type = Int
            default = 3
        "--num-cells-init" # TO JSON
            help = "Initial number of cells. Ignored if CSV with centers is provided."
            arg_type = Int
            default = 100
        "--output", "-o"
            help = "Name of the output file or path to the output directory"
            default = "segmentation.csv"
        "--plot", "-p"
            help = "Save pdf with plot of the segmentation"
            action = :store_true
        "--plot-frame-size"
            help = "Size of frame, which is used for result plotting. Ignored without '-v' option."
            arg_type = Float64
            default = 5000.0

        "--center-component-weight" # TO JSON
            help = "Prior weight of assignment a molecule to new component, created from DAPI centers. Paramter of Dirichlet process. Ignored if CSV with centers is not provided."
            arg_type = Float64
            default = 1.0
        "--new-component-weight" # TO JSON
            help = "Prior weight of assignment a molecule to new component. Paramter of Dirichlet process."
            arg_type = Float64
            default = 0.1
        "--new-component-fraction" # TO JSON
            help = "Fraction of distributions, sampled at each stage. Paramter of Dirichlet process."
            arg_type = Float64
            default = 0.2
        "--n-degrees-of-freedom-center" # TO JSON
            help = "Number of degrees of freedom for cell center distribution, used for posterior estimates of parameters. Ignored if centers are not provided. Default: equal to min-molecules-per-cell."
            arg_type = Int
        "--shape-deg-freedom" # TODO: make it depend on mean number of molecules # TO JSON
            help = "Number of degrees of freedom for shape prior. Normally should be several times larger than expected number of molecules per cell."
            arg_type = Int
            default = 1000
        "--n-frames", "-n"
            help = "Number of frames, which is the same as number of processes. Algorithm data is splitted by frames to allow parallel run over frames."
            arg_type = Int
            default=1
        "--gene-composition-neigborhood"
            help = "Number of neighbors (i.e. 'k'), which is used for gene composition visualization. Larger numbers leads to more global patterns."
            arg_type = Int
            default=20

        "--scale", "-s"
            help = "Scale parameter, which suggest approximate cell radius for the algorithm"
            arg_type = Float64

        "coordinates"
            help = "CSV file with coordinates of transcripts and gene type"
            required = true
        "centers"
            help = "CSV file with coordinates of cell centers, extracted from DAPI staining"
    end

    r = (args === nothing) ? parse_args(s) : parse_args(args, s)

    for k in ["gene", "x", "y"]
        r[k] = Symbol(r[k])
    end

    if r["n-degrees-of-freedom-center"] === nothing
        r["n-degrees-of-freedom-center"] = r["min-molecules-per-cell"]
    end

    if r["centers"] === nothing && r["scale"] === nothing
        print("Either `centers` or `scale` must be provided.\n" * usage_string(s) * "\n")
        exit(1)
    end

    if isdir(r["output"]) || isdirpath(r["output"])
        r["output"] = joinpath(r["output"], "segmentation.csv")
    end

    return r
end

load_df(args::Dict) = load_df(args["coordinates"]; x_col=args["x"], y_col=args["y"], gene_col=args["gene"], min_molecules_per_gene=args["min-molecules-per-gene"])

append_suffix(output::String, suffix) = "$(splitext(output)[1])_$suffix"

function plot_results(df_res::DataFrame, assignment::Array{Int, 1}, df_centers::Union{DataFrame, Nothing}, tracer::Dict, args::Dict{String,Any})
    ## Convergence
    p1 = plot_num_of_cells_per_iterarion(tracer);
    Plots.savefig(append_suffix(args["output"], "convergence.pdf"))

    ## Transcripts
    neighb_cm = neighborhood_count_matrix(df_res, args["gene-composition-neigborhood"]);
    color_transformation = gene_composition_transformation(neighb_cm)

    frame_size = args["plot-frame-size"]

    borders = [(minimum(df_res[!, s]), maximum(df_res[!, s])) for s in [:x, :y]];
    borders = [collect(range(b[1], b[1] + floor((b[2] - b[1]) / frame_size) * frame_size, step=frame_size)) for b in borders]
    borders = collect(Iterators.product(borders...));

    plot_info = @showprogress "Extracting plot info..." pmap(borders) do b
        extract_plot_information(df_res, assignment, b..., df_centers=df_centers, color_transformation=color_transformation, 
            k=args["gene-composition-neigborhood"], frame_size=frame_size, min_molecules_per_cell=args["min-molecules-per-gene"], plot=true)
    end;
    plot_info = plot_info[length.(plot_info) .> 0];

    plot_width = 600
    p1 = Plots.plot([d[:plot] for d in plot_info]..., layout=(length(plot_info), 1), size=(plot_width, plot_width * length(plot_info)));
    Plots.savefig(append_suffix(args["output"], "borders.pdf"))
end

function run_cli(args::Union{Nothing, Array{String, 1}, String}=nothing)
    if args == "build"
        return 0
    end

    arg_string = join(ARGS, " ")
    args = parse_commandline(args)

    @info "Run"
    @info "Load data..."
    df_spatial, gene_names = load_df(args)

    df_centers = nothing
    bm_data_arr = BmmData[]
    confidence_nn_id = max(div(args["min-molecules-per-cell"], 2) + 1, 3)

    if args["centers"] !== nothing
        centers = load_centers(args["centers"], x_col=args["x"], y_col=args["y"])
        df_centers = centers.centers

        bm_data_arr = initial_distribution_arr(df_spatial, centers; n_frames=args["n-frames"],
            shape_deg_freedom=args["shape-deg-freedom"], scale=args["scale"], n_cells_init=args["num-cells-init"],
            new_component_weight=args["new-component-weight"], center_component_weight=args["center-component-weight"], 
            n_degrees_of_freedom_center=args["n-degrees-of-freedom-center"], confidence_nn_id=confidence_nn_id);
    else
        bm_data_arr = initial_distribution_arr(df_spatial; n_frames=args["n-frames"],
            shape_deg_freedom=args["shape-deg-freedom"], scale=args["scale"], n_cells_init=args["num-cells-init"],
            new_component_weight=args["new-component-weight"], confidence_nn_id=confidence_nn_id);
    end

    if length(bm_data_arr) > 1
        addprocs(length(bm_data_arr) - nprocs())
        eval(:(@everywhere using Baysor))
    end

    bm_data = run_bmm_parallel(bm_data_arr, args["iters"], new_component_frac=args["new-component-fraction"],
                               min_molecules_per_cell=args["min-molecules-per-cell"], n_refinement_iters=args["refinement-iters"]);

    @info "Processing complete."

    segmentated_df = get_segmentation_df(bm_data, gene_names)
    cell_stat_df = get_cell_stat_df(bm_data; add_qc=true)

    @info "Save data to $(args["output"])"
    CSV.write(args["output"], segmentated_df);
    CSV.write(append_suffix(args["output"], "cell_stats.csv"), cell_stat_df);

    open(append_suffix(args["output"], "args.dump"), "w") do f
        write(f, arg_string)
    end    

    if args["plot"]
        @info "Plot results"
        plot_results(bm_data.x, bm_data.assignment, df_centers, bm_data.tracer, args)
    end

    @info "All done!"

    return 0
end