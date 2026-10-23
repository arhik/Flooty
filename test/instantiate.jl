using Pkg
Pkg.activate(dirname(@__DIR__))
Pkg.resolve()
Pkg.instantiate()
println("INSTANTIATE_DONE")
