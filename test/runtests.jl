using Test
using DataFrames
using Distributions
using LinearAlgebra
using Statistics
using StatsBase

import Random: seed!
import Baysor as B

module DataWrappers

using DataFrames
import Baysor as B

function get_bmm_data(; n_mols::Int=5000, confidence::Bool=false, scale::Float64=0.1, min_molecules_per_cell::Int=10, do_maximize::Bool=false, kwargs...)
    df = DataFrame(:x => rand(n_mols), :y => rand(n_mols), :gene => rand(1:10, n_mols), :confidence => confidence ? ones(n_mols) : rand(n_mols))
    bmd = B.initialize_bmm_data(df, scale=scale, min_molecules_per_cell=min_molecules_per_cell, confidence_nn_id=0, kwargs...);
    if do_maximize
        B.maximize!(bmd)
    end

    return bmd
end

end

@testset "Baysor" begin
    @testset "utils" begin
        @testset "convex_hull" begin
            chull = B.convex_hull([[0, 0], [1, 0], [0, 0], [1, 1], [0, 1]])
            @test all(chull .== [0 0 1 1 0; 0 1 1 0 0])
            @test B.area(chull) ≈ 1.0

            chull = B.convex_hull([[0, 0], [1, 0], [0, 0], [1, 1], [0, 1], [0, 2], [2, 0]])
            @test all(chull .== [0 0 2 0; 0 2 0 0])
            @test B.area(chull) ≈ 2.0

            chull = B.convex_hull([[0, 0], [1, 0], [0, 0], [1, 1], [0, 1], [0, 2], [2, 0], [2, 2]])
            @test all(chull .== [0 0 2 2 0; 0 2 2 0 0])
            @test B.area(chull) ≈ 4.0
        end
    end

    @testset "distributions" begin
        @testset "ShapePrior" begin
            seed!(42)

            means = B.MeanVec{2}([10.0, 20.0])
            std_stds = B.MeanVec{2}([5.0, 10.0])
            stds = hcat([Vector(B.sample_var(B.ShapePrior{2}(means, std_stds, 1000))) for i in 1:100000]...) .^ 0.5
            @test all(stds .> 0)
            @test all(abs.(vec(mean(stds, dims=2)) .- means) .< 1)

            means = B.MeanVec{2}([1000.0, 2000.0])
            stds = hcat([Vector(B.sample_var(B.ShapePrior{2}(means, std_stds, 1000))) for i in 1:100000]...) .^ 0.5
            @test all(stds .> 0)
            @test all(abs.(vec(mean(stds, dims=2)) .- means) .< 1)
            @test all(abs.(vec(std(stds, dims=2)) .- std_stds) .< 1)
        end

        @testset "CategoricalSmoothed" begin
            dist = B.CategoricalSmoothed([0.0, 0.0, 0.0])
            B.maximize!(dist, [missing, 1, 2], [0.5, 0.5, 0.5])
            @test all(dist.counts .≈ [0.5, 0.5, 0.0])
            @test dist.sum_counts ≈ 1.0
        end
    end

    @testset "data_processing" begin
        @testset "initialization" begin
            n_mols = 1000
            df = DataFrame(:x => rand(n_mols), :y => rand(n_mols), :gene => rand(1:10, n_mols))

            df[!, :cluster] = rand(1:5, n_mols)
            df[!, :prior_segmentation] = rand(1:100, n_mols)
            bm_data = B.initialize_bmm_data(df, scale=6.0, min_molecules_per_cell=30);
            @test all(bm_data.cluster_per_molecule .== df.cluster)
            @test all(bm_data.segment_per_molecule .== df.prior_segmentation)

            @test all(length(bm_data.adjacent_points[i]) == length(bm_data.adjacent_weights[i]) for i in 1:length(bm_data.adjacent_points))
            @test !any(i in bm_data.adjacent_points[i] for i in 1:length(bm_data.adjacent_points))

            for i in 5:10:55
                init_params = B.cell_centers_uniformly(df, i; scale=10.0)
                @test size(init_params.centers, 1) == i
                @test size(init_params.centers, 2) == 2
                @test length(init_params.covs) == i
                @test maximum(init_params.assignment) == i
            end
        end

        @testset "parse_parameters" begin
            @test B.parse_scale_std("23.55%", 121.0) ≈ 121.0 * 0.2355
            @test B.parse_scale_std(33.87, 121.0) ≈ 33.87
            @test B.parse_scale_std(nothing, 121.0) ≈ 121.0 * 0.25
        end

        @testset "molecule_graph" begin
            for adj_type in [:triangulation, :knn, :both]
                adj_points, adj_weights = B.build_molecule_graph(DataFrame(rand(1000, 2), [:x, :y]); adjacency_type=adj_type, k_adj=30)[1:2];
                @test all(length.(adj_points) .== length.(adj_weights))
                @test all(length.(adj_points) .== length.(unique.(adj_points)))
            end
        end

        @testset "filter_segmentation" begin
            labels = [1 2 3; 1 2 4; 5 2 7];
            position_data = hcat(vec([[id[1], id[2]] for id in CartesianIndices(labels)])...)
            df_spatial = DataFrame(:x => position_data[1,:], :y => position_data[2,:])
            assignment = B.staining_value_per_transcript(df_spatial, labels)

            expected_results = [
                labels,
                labels,
                [1 2 0; 1 2 0; 0 2 0],
                [0 2 0; 0 2 0; 0 2 0],
                [0 0 0; 0 0 0; 0 0 0]
            ]
            for m in 0:4
                l, ta = B.filter_segmentation_labels!(deepcopy(labels), deepcopy(assignment), min_molecules_per_segment=m)
                @test all(l .== expected_results[m + 1])

                a = B.filter_segmentation_labels!(deepcopy(assignment), min_molecules_per_segment=m)
                @test all(a .== B.staining_value_per_transcript(df_spatial, l))
                @test all(a .== ta)
            end
        end
    end

    @testset "bmm_algorithm" begin
        @testset "noise_composition_density" begin
            for conf in [false, true]
                bm_data = DataWrappers.get_bmm_data(confidence=conf, do_maximize=true);
                dens_exp = mean([mean(c.composition_params.counts[c.composition_params.counts .> 0] ./ c.composition_params.sum_counts) for c in bm_data.components]);
                dens_obs = B.noise_composition_density(bm_data)
                @test abs(dens_exp - dens_obs) < 1e-10
            end
        end

        @testset "distribution_sampling" begin
            bm_data = DataWrappers.get_bmm_data(confidence=true, do_maximize=true);
            @test_nowarn for i in 1:1000
                B.sample_distribution!(bm_data)
            end
        end

        @testset "drop_unused_components" begin
            bm_data = DataWrappers.get_bmm_data(n_mols=1000, confidence=true);
            bm_data.assignment[rand(1:length(bm_data.assignment), 100)] .= 0
            B.maximize!(bm_data)
            B.drop_unused_components!(bm_data)

            @test all(B.num_of_molecules_per_cell(bm_data) .== [c.n_samples for c in bm_data.components])
        end

        @testset "maximize_mvnormal" begin
            is_not_nan = map(1:10000) do i
                n_samps = rand(0:100)
                d = B.MvNormalF([0., 0.], diagm(0 => ones(2)));
                B.maximize!(d, rand(2, n_samps); center_probs=rand(n_samps) .* rand(Binomial(1, 0.5), n_samps))
                !isnan(d.Σ[1])
            end

            @test all(is_not_nan)
        end

        @testset "synthetic_run" begin
            seed!(42)
            for it in 1:6
                n_components = 10;
                n_genes = 20
                scale = 0.2;
                frame_size = (100, 200)
                centers = hcat(rand(n_components) * frame_size[1], rand(n_components) * frame_size[2]);
                sizes = rand(Poisson(50), n_components);
                expressions = rand(Dirichlet(n_genes, 0.1), n_components);

                df_spatial = vcat([DataFrame(
                    :x => rand(Normal(centers[i,1], scale), sizes[i]),
                    :y => rand(Normal(centers[i,2], scale), sizes[i]),
                    :gene => rand(Categorical(expressions[:,i]), sizes[i]),
                    :cell => i
                ) for i in 1:n_components]...)

                noise_size = 100
                df_spatial = vcat(df_spatial, DataFrame(:x => rand(noise_size) * frame_size[1], :y => rand(noise_size) * frame_size[2],
                    :gene => rand(1:n_genes, noise_size), :cell => 0));

                if it % 2 == 0
                    df_spatial[!, :z] = rand(1:3, size(df_spatial, 1)) .* scale ./ 10
                end

                if it > 4
                    df_spatial[!, :cluster] = df_spatial.cell .+ 1
                end
                bm_data_arr = B.initialize_bmm_data(df_spatial; scale=scale, scale_std="5%", min_molecules_per_cell=10);
                bm_data = B.bmm!(bm_data_arr; n_iters=300, new_component_frac=0.3, min_molecules_per_cell=10, assignment_history_depth=50, verbose=false);

                conj_table = counts(B.estimate_assignment_by_history(bm_data)[1], df_spatial.cell)[2:end, 2:end];
                @test all([all(vec(mapslices(maximum, conj_table ./ sum(conj_table, dims=d), dims=d)) .> 0.5) for d in 1:2])

                # Test that it works
                seg_df = B.get_segmentation_df(bm_data)
                gene_names = ["g$i" for i in 1:maximum(df_spatial.gene)]
                seg_df = B.get_segmentation_df(bm_data, gene_names)
                df_res = B.get_cell_stat_df(bm_data, seg_df)
                cm1 = B.convert_segmentation_to_counts(B.composition_data(bm_data), bm_data.assignment)
                cm2 = B.convert_segmentation_to_counts(B.composition_data(bm_data), bm_data.assignment; gene_names=gene_names)
                @test all((size(cm2[:, 2:end]) .== size(cm1)))
            end
        end
    end
end