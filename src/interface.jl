# Wrapper for the low level functions defined in https://github.com/oxfordcontrol/osqp/blob/master/include/osqp.h

# Ensure compatibility between Julia versions with @gc_preserve
macro compat_gc_preserve(args...)
    vars = args[1:end - 1]
    body = args[end]
    if VERSION > v"0.7.0-"
        return esc(Expr(:macrocall, Expr(:., :Base, Base.Meta.quot(Symbol("@gc_preserve"))), __source__, args...))
    else
        return esc(body)
    end
end

mutable struct Model
    workspace::Ptr{OSQP.Workspace}

    """
        Module()

    Initialize OSQP module
    """
    function Model()
            # TODO: Change me to more elegant way
            # a = Array{Ptr{OSQP.Workspace}}(1)[1]
        a = C_NULL

            # Create new model
        model = new(a)

            # Add finalizer
        @compat finalizer(OSQP.clean!, model)

        return model

    end


end

"""
    setup!(model, P, q, A, l, u, settings)

Perform OSQP solver setup of model `model`, using the inputs `P`, `q`, `A`, `l`, `u`.
"""
function setup!(model::OSQP.Model;
        P::Union{SparseMatrixCSC,Nothing} = nothing,
        q::Union{Vector{Float64},Nothing} = nothing,
        A::Union{SparseMatrixCSC,Nothing} = nothing,
        l::Union{Vector{Float64},Nothing} = nothing,
        u::Union{Vector{Float64},Nothing} = nothing,
        settings...)

    # Check problem dimensions
    if P == nothing
        if q != nothing
            n = length(q)
        elseif A != nothing
            n = size(A, 2)
        else
            error("The problem does not have any variables!")
        end

    else
        n = size(P, 1)
    end

    if A == nothing
        m = 0
    else
        m = size(A, 1)
    end


    # Check if parameters are nothing
    if ((A == nothing) & ( (l != nothing) | (u != nothing))) |
        ((A != nothing) & ((l == nothing) | (u == nothing)))
        error("A must be supplied together with l and u")
    end

    if (A != nothing) & (l == nothing)
        l = -Inf * ones(m)
    end
    if (A != nothing) & (u == nothing)
        u = Inf * ones(m)
    end

    if P == nothing
        P = sparse([], [], [], n, n)
    end
    if q == nothing
        q = zeros(n)
    end
    if A == nothing
        A = sparse([], [], [], m, n)
        l = zeros(m)
        u = zeros(m)
    end


    # Check if dimensions are correct
    if length(q) != n
        error("Incorrect dimension of q")
    end
    if length(l) != m
        error("Incorrect dimensions of l")
    end
    if length(u) != m
        error("Incorrect dimensions of u")
    end


    # Check or sparsify matrices
    if !issparse(P)
        warn("P is not sparse. Sparsifying it now (it might take a while)")
        P = sparse(P)
    end
    if !issparse(A)
        warn("A is not sparse. Sparsifying it now (it might take a while)")
        A = sparse(A)
    end

    # Convert lower and upper bounds from Julia infinity to OSQP infinity
    u = min.(u, OSQP_INFTY)
    l = max.(l, -OSQP_INFTY)

    # Create managed matrices to avoid segfaults (See SCS.jl)
    managedP = OSQP.ManagedCcsc(P)
    managedA = OSQP.ManagedCcsc(A)

    # Get managed pointers (Ref) Pdata and Adata
    Pdata = Ref(OSQP.Ccsc(managedP))
    Adata = Ref(OSQP.Ccsc(managedA))

    # Create OSQP data using the managed matrices pointers
    data = OSQP.Data(n, m,
                     Base.unsafe_convert(Ptr{OSQP.Ccsc}, Pdata),
                     Base.unsafe_convert(Ptr{OSQP.Ccsc}, Adata),
                     pointer(q),
                     pointer(l), pointer(u))

    # Create OSQP settings
    settings_dict = Dict{Symbol,Any}()
    if !isempty(settings)
        for (key, value) in settings
            settings_dict[key] = value
        end
    end

    stgs = OSQP.Settings(settings_dict)

    # Perform setup
    @compat_gc_preserve managedP Pdata managedA Adata q l u begin
        model.workspace = ccall((:osqp_setup, OSQP.osqp),
                    Ptr{OSQP.Workspace}, (Ptr{OSQP.Data},
                                          Ptr{OSQP.Settings}),
                    Ref(data), Ref(stgs))
    end

    if model.workspace == C_NULL
        error("Error in OSQP setup")
    end

end


function solve!(model::OSQP.Model)

    # Solve problem
    ccall((:osqp_solve, OSQP.osqp), Cc_int,
             (Ptr{OSQP.Workspace}, ),
             model.workspace)

    # Recover solution
    workspace = unsafe_load(model.workspace)
    solution = unsafe_load(workspace.solution)
    data = unsafe_load(workspace.data)

    # Recover Cinfo structure
    cinfo = unsafe_load(workspace.info)

    # Construct C structure
    info = OSQP.Info(cinfo)

    # Do not use this anymore. We instead copy the solution
    # x = unsafe_wrap(Array, solution.x, data.n)
    # y = unsafe_wrap(Array, solution.y, data.m)

    # Allocate solution vectors and copy solution
    x = Array{Float64}(uninitialized, data.n)
    y = Array{Float64}(uninitialized, data.m)

    if info.status in SOLUTION_PRESENT
        # If solution exists, copy it
        unsafe_copyto!(pointer(x), solution.x, data.n)
        unsafe_copyto!(pointer(y), solution.y, data.m)

        # Return results
        return Results(x, y, info)
    else
        # else fill with NaN and return certificates of infeasibility
        x *= NaN
        y *= NaN
        if info.status == :Primal_infeasible || info.status == :Primal_infeasible_inaccurate
            prim_inf_cert = Array{Float64}(uninitialized, data.m)
            unsafe_copyto!(pointer(prim_inf_cert), workspace.delta_y, data.m)
            # Return results
            return Results(x, y, info, prim_inf_cert, nothing)
        elseif info.status == :Dual_infeasible || info.status == :Dual_infeasible_inaccurate
            dual_inf_cert = Array{Float64}(uninitialized, data.n)
            unsafe_copyto!(pointer(dual_inf_cert), workspace.delta_x, data.n)
            # Return results
            return Results(x, y, info, nothing, dual_inf_cert)
        else
            # Other kind of exit reasons like time_limit or signal interrupt
            return Results(x, y, info)            
        end
    end
    error() # fixes #4
end


function version()
    return unsafe_string(ccall((:osqp_version, OSQP.osqp), Cstring, ()))
end

function clean!(model::OSQP.Model)
    exitflag = ccall((:osqp_cleanup, OSQP.osqp), Cc_int,
             (Ptr{OSQP.Workspace},), model.workspace)
    if exitflag != 0
        error("Error in OSQP cleanup")
    end
end

function update_q!(model::OSQP.Model, q::Vector{Float64})
    (n, m) = OSQP.dimensions(model)
    if length(q) != n
        error("q must have length n = $(n)")
    end
    exitflag = ccall((:osqp_update_lin_cost, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Ptr{Cdouble}), model.workspace, q)
    if exitflag != 0 error("Error updating q") end
end

function update_l!(model::OSQP.Model, l::Vector{Float64})
    (n, m) = OSQP.dimensions(model)
    if length(l) != m
        error("l must have length m = $(m)")
    end
    l .= max.(l, -OSQP_INFTY) # Convert values to OSQP_INFTY
    exitflag = ccall((:osqp_update_lower_bound, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Ptr{Cdouble}), model.workspace, l)
    if exitflag != 0 error("Error updating l") end
end

function update_u!(model::OSQP.Model, u::Vector{Float64})
    (n, m) = OSQP.dimensions(model)
    if length(u) != m
        error("u must have length m = $(m)")
    end
    u .= min.(u, OSQP_INFTY) # Convert values to OSQP_INFTY
    exitflag = ccall((:osqp_update_upper_bound, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Ptr{Cdouble}), model.workspace, u)
    if exitflag != 0 error("Error updating u") end
end

function update_bounds!(model::OSQP.Model, l::Vector{Float64}, u::Vector{Float64})
    (n, m) = OSQP.dimensions(model)
    if length(l) != m
        error("l must have length m = $(m)")
    end
    if length(u) != m
        error("u must have length m = $(m)")
    end
    exitflag = ccall((:osqp_update_bounds, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Ptr{Cdouble}, Ptr{Cdouble}), model.workspace, l, u)
    if exitflag != 0 error("Error updating bounds l and u") end
end

prep_idx_vector_for_ccall(idx::Nothing, n::Int, namesym::Symbol) = C_NULL
function prep_idx_vector_for_ccall(idx::Vector{Int}, n::Int, namesym::Symbol)
    if length(idx) != n
        error("$(namesym) and $(namesym)_idx must have the same length")
    end
    idx .-= 1 # Shift indexing to match C
    idx
end

restore_idx_vector_after_ccall!(idx::Nothing) = nothing
function restore_idx_vector_after_ccall!(idx::Vector{Int})
    idx .+= 1 # Unshift indexing
    nothing
end

function update_P!(model::OSQP.Model, Px::Vector{Float64}, Px_idx::Union{Vector{Int}, Nothing})
    Px_idx_prepped = prep_idx_vector_for_ccall(Px_idx, length(Px), :P)
    exitflag = ccall((:osqp_update_P, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Ptr{Cdouble}, Ptr{Cc_int}, Cc_int),
        model.workspace, Px, Px_idx_prepped, length(Px))
    restore_idx_vector_after_ccall!(Px_idx)
    if exitflag != 0 error("Error updating P") end
end

function update_A!(model::OSQP.Model, Ax::Vector{Float64}, Ax_idx::Union{Vector{Int}, Nothing})
    Ax_idx_prepped = prep_idx_vector_for_ccall(Ax_idx, length(Ax), :A)
    exitflag = ccall((:osqp_update_A, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Ptr{Cdouble}, Ptr{Cc_int}, Cc_int),
        model.workspace, Ax, Ax_idx_prepped, length(Ax))
    restore_idx_vector_after_ccall!(Ax_idx)
    if exitflag != 0 error("Error updating A") end
end

function update_P_A!(model::OSQP.Model, Px::Vector{Float64}, Px_idx::Union{Vector{Int}, Nothing}, Ax::Vector{Float64}, Ax_idx::Union{Vector{Int}, Nothing})
    Px_idx_prepped = prep_idx_vector_for_ccall(Px_idx, length(Px), :P)
    Ax_idx_prepped = prep_idx_vector_for_ccall(Ax_idx, length(Ax), :A)
    exitflag = ccall((:osqp_update_P_A, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Ptr{Cdouble},
        Ptr{Cc_int}, Cc_int, Ptr{Cdouble}, Ptr{Cc_int}, Cc_int),
        model.workspace, Px, Px_idx_prepped, length(Px), Ax, Ax_idx_prepped, length(Ax))
    restore_idx_vector_after_ccall!(Ax_idx)
    restore_idx_vector_after_ccall!(Px_idx)
    if exitflag != 0 error("Error updating P and A") end
end

function update!(model::OSQP.Model; q = nothing, l = nothing, u = nothing, Px = nothing, Px_idx = nothing, Ax = nothing, Ax_idx = nothing)
    # q
    if q != nothing
        update_q!(model, q)
    end

    # l and u
    if l != nothing && u != nothing
        update_bounds!(model, l, u)
    elseif l != nothing
        update_l!(model, l)
    elseif u != nothing
        update_u!(model, u)
    end

    # P and A
    if Px != nothing && Ax != nothing
        update_P_A!(model, Px, Px_idx, Ax, Ax_idx)
    elseif Px != nothing
        update_P!(model, Px, Px_idx)
    elseif Ax != nothing
        update_A!(model, Ax, Ax_idx)
    end
end



function update_settings!(model::OSQP.Model; kwargs...)

    if isempty(kwargs)
        return
    else
        data = Dict{Symbol,Any}()
        for (key, value) in kwargs
            if !(key in UPDATABLE_SETTINGS)
                error("$(key) cannot be updated or is not recognized")
            else
                data[key] = value
            end
        end
    end

    # Get arguments
    max_iter = get(data, :max_iter, nothing)
    eps_abs = get(data, :eps_abs, nothing)
    eps_rel = get(data, :eps_rel, nothing)
    eps_prim_inf = get(data, :eps_prim_inf, nothing)
    eps_dual_inf = get(data, :eps_dual_inf, nothing)
    rho = get(data, :rho, nothing)
    alpha = get(data, :alpha, nothing)
    delta = get(data, :delta, nothing)
    polish = get(data, :polish, nothing)
    polish_refine_iter = get(data, :polish_refine_iter, nothing)
    verbose = get(data, :verbose, nothing)
    scaled_termination = get(data, :early_terminate, nothing)
    check_termination = get(data, :check_termination, nothing)
    warm_start = get(data, :warm_start, nothing)
    time_limit = get(data, :time_limit, nothing)

    # Update individual settings
    if max_iter != nothing
        exitflag = ccall((:osqp_update_max_iter, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cc_int), model.workspace, max_iter)
        if exitflag != 0 error("Error updating max_iter") end
    end

    if eps_abs != nothing
        exitflag = ccall((:osqp_update_eps_abs, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cdouble), model.workspace, eps_abs)
        if exitflag != 0 error("Error updating eps_abs") end
    end

    if eps_rel != nothing
        exitflag = ccall((:osqp_update_eps_rel, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cdouble), model.workspace, eps_rel)
        if exitflag != 0 error("Error updating eps_rel") end
    end


    if eps_prim_inf != nothing
        exitflag = ccall((:osqp_update_eps_prim_inf, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cdouble), model.workspace, eps_prim_inf)
        if exitflag != 0 error("Error updating eps_prim_inf") end
    end

    if eps_dual_inf != nothing
        exitflag = ccall((:osqp_update_eps_dual_inf, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cdouble), model.workspace, eps_dual_inf)
        if exitflag != 0 error("Error updating eps_dual_inf") end
    end

    if rho != nothing
        exitflag = ccall((:osqp_update_rho, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cdouble), model.workspace, rho)
        if exitflag != 0 error("Error updating rho") end
    end

    if alpha != nothing
        exitflag = ccall((:osqp_update_alpha, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cdouble), model.workspace, alpha)
        if exitflag != 0 error("Error updating alpha") end
    end

    if delta != nothing
        exitflag = ccall((:osqp_update_delta, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cdouble), model.workspace, delta)
        if exitflag != 0 error("Error updating delta") end
    end

    if polish != nothing
        exitflag = ccall((:osqp_update_polish, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cc_int), model.workspace, polish)
        if exitflag != 0 error("Error updating polish") end
    end

    if polish_refine_iter != nothing
        exitflag = ccall((:osqp_update_polish_refine_iter, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cc_int), model.workspace, polish_refine_iter)
        if exitflag != 0 error("Error updating polish_refine_iter") end
    end

    if verbose != nothing
        exitflag = ccall((:osqp_update_verbose, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cc_int), model.workspace, verbose)
        if exitflag != 0 error("Error updating verbose") end
    end

    if scaled_termination != nothing
        exitflag = ccall((:osqp_update_scaled_termination, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cc_int), model.workspace, scaled_termination)
        if exitflag != 0 error("Error updating scaled_termination") end
    end

    if check_termination != nothing
        exitflag = ccall((:osqp_update_check_termination, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cc_int), model.workspace, check_termination)
        if exitflag != 0 error("Error updating check_termination") end
    end

    if warm_start != nothing
        exitflag = ccall((:osqp_update_warm_start, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cc_int), model.workspace, warm_start)
        if exitflag != 0 error("Error updating warm_start") end
    end

   if time_limit != nothing
        exitflag = ccall((:osqp_update_time_limit, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Cdouble), model.workspace, time_limit)
        if exitflag != 0 error("Error updating time_limit") end
    end

    return nothing
end



function warm_start!(model::OSQP.Model; x::Union{Vector{Float64}, Nothing} = nothing, y::Union{Vector{Float64}, Nothing} = nothing)
    # Get problem dimensions
    (n, m) = OSQP.dimensions(model)

    if x != nothing
        if length(x) != n
            error("Wrong dimension for variable x")
        end

        if y == nothing
            exitflag = ccall((:osqp_warm_start_x, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Ptr{Cdouble}), model.workspace, x)
            if exitflag != 0 error("Error in warm starting x") end
        end
    end


    if y != nothing
        if length(y) != m
            error("Wrong dimension for variable y")
        end

        if x == nothing
            exitflag = ccall((:osqp_warm_start_y, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Ptr{Cdouble}), model.workspace, y)
            if exitflag != 0 error("Error in warm starting y") end
        end
    end

    if (x != nothing) & (y != nothing)
        exitflag = ccall((:osqp_warm_start, OSQP.osqp), Cc_int, (Ptr{OSQP.Workspace}, Ptr{Cdouble}, Ptr{Cdouble}), model.workspace, x, y)
        if exitflag != 0 error("Error in warm starting x and y") end
    end

end



# Auxiliary low-level functions
"""
    dimensions(model::OSQP.Model)

Obtain problem dimensions from OSQP model
"""
function dimensions(model::OSQP.Model)

    workspace = unsafe_load(model.workspace)
    if workspace == C_NULL
        error("Workspace has not been setup yet")
    end
    data = unsafe_load(workspace.data)
    return data.n, data.m
end




function linsys_solver_str_to_int!(settings_dict::Dict{Symbol,Any})
         # linsys_str = pop!(settings_dict, :linsys_solver)
    linsys_str = get(settings_dict, :linsys_solver, nothing)

    if linsys_str != nothing
         # Check type
        if !isa(linsys_str, String)
            error("linsys_solver is required to be a string")
        end

         # Convert to lower case
        linsys_str = lowercase(linsys_str)

        if linsys_str == "suitesparse ldl"
            settings_dict[:linsys_solver] = SUITESPARSE_LDL_SOLVER
        elseif linsys_str == "mkl pardiso"
            settings_dict[:linsys_solver] = MKL_PARDISO_SOLVER
        elseif linsys_str == ""
            settings_dict[:linsys_solver] = SUITESPARSE_LDL_SOLVER
        else
            warn("Linear system solver not recognized. Using default SuiteSparse LDL")
            settings_dict[:linsys_solver] = SUITESPARSE_LDL_SOLVER

        end
    end
end
