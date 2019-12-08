using SparseArrays: SparseMatrixCSC, sparse
using LinearAlgebra: I
using OSQP: Ccsc, ManagedCcsc
@testset "sparse matrix interface roundtrip" begin
    jl = sparse(Matrix{Bool}(LinearAlgebra.I, 5, 5))
    mc = ManagedCcsc(jl)
    c = Ccsc(mc)
    jl2 = convert(SparseMatrixCSC, c)
    @test jl == jl2
end
