#! /usr/bin/env julia

using PackageCompiler
import Pkg

out_path = length(ARGS) > 1 ? ARGS[1] : "Baysor";
baysor_path = length(ARGS) > 2 ? ARGS[2] : dirname(@__DIR__);

Base.LOAD_PATH .= baysor_path
create_app(baysor_path, out_path; precompile_execution_file="$(baysor_path)/bin/precompile.jl", include_lazy_artifacts=true)
