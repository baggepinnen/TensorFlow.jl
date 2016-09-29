using Distributions

type Variable <: AbstractTensor
    var_node::Operation
    assign_node::Operation

    Variable() = new()
end

function Variable(initial_value; name="", trainable=true, literal_name=false)
    self = Variable()
    if !literal_name
        name = get_name(name)
    end
    desc = NodeDescription("Variable", name)
    desc["dtype"] = eltype(initial_value)
    desc["shape"] = size(initial_value)
    self.var_node = Operation(desc)

    desc = NodeDescription("Assign", "$name/Assign")
    add_input(desc, self.var_node)
    t = Tensor(initial_value)
    add_input(desc, t)
    self.assign_node = Operation(desc)
    add_to_collection(:Variables, self)
    if trainable
        add_to_collection(:TrainableVariables, self)
    end
    return self
end

function assign(v::Variable, value)
    desc = NodeDescription(get_def_graph(), "Assign", get_name())
    add_input(desc, v.var_node)
    add_input(desc, Tensor(value))
    return Tensor(Operation(desc), 1)
end

function assign_sub(v::Variable, value)
    desc = NodeDescription("AssignSub", get_name())
    add_input(desc, v.var_node)
    add_input(desc, Tensor(value))
    return Tensor(Operation(desc), 1)
end

function scatter_update(ref, indices, updates; name="ScatterUpdate")
    local desc
    with_op_name(name) do
        desc = NodeDescription("ScatterUpdate")
        add_input(desc, Tensor(ref))
        add_input(desc, Tensor(indices))
        add_input(desc, Tensor(updates))
    end
    Tensor(Operation(desc))
end

function scatter_sub(ref, indices, updates; name="ScatterSub")
    local desc
    with_op_name(name) do
        desc = NodeDescription("ScatterSub")
        add_input(desc, Tensor(ref))
        add_input(desc, Tensor(indices))
        add_input(desc, Tensor(updates))
    end
    Tensor(Operation(desc))
end

Base.setindex!(v::Variable, value) = assign(v, value)

Base.convert(::Type{Tensor}, v::Variable) = Tensor(v.var_node, 1)

function initialize_all_variables()
    return group([Tensor(var.assign_node) for var in get_collection(:Variables)]...)
end

run(sess::Session, var::Variable) = run(sess, Tensor(var))
run(sess::Session, vars::AbstractVector{Variable}) = run(sess, map(Tensor, vars))

type Scope
    name::Nullable{String}
    initializer::Nullable{Any}
    reuse::Bool
    Scope() = new(Nullable{String}(), Nullable{Any}(), false)
end

const scope_stack = Scope[]

function make_scope(name; initializer=nothing, reuse=false)
    scope = Scope()
    scope.name = Nullable(name)
    if initializer != nothing
        scope.initializer = Nullable(initializer)
    end
    scope.reuse = reuse
    return scope
end

function variable_scope(f, name; kwargs...)
    scope = make_scope(name; kwargs...)
    push!(scope_stack, scope)
    try
        f()
    finally
        pop!(scope_stack)
    end
end

get_dims(t::AbstractTensorShape) = map(get, t.dims)
get_dims(x) = x

function get_variable(var_name, shape, dtype; trainable=true, kwargs...)
    shape = get_dims(shape)
    scope = make_scope(var_name; kwargs...)
    push!(scope_stack, scope)
    name = join([get(_.name) for _ in scope_stack], "/")
    local v
    try
        initializer = Normal(0, .01)
        reuse = false
        for scope in scope_stack
            if !isnull(scope.initializer)
                initializer = get(scope.initializer)
            end
            if scope.reuse
                reuse = true
            end
        end
        if reuse
            n = get_node_by_name(get_def_graph(), name)
            v = Variable()
            v.var_node = get_node_by_name(name) |> get
            v.assign_node = get_node_by_name("$name/Assign") |> get
        else
            if length(shape) > 0
                iv = rand(initializer, shape...)
            else
                iv = rand(initializer, 1)[1]
            end
            v = Variable(map(dtype, iv), name=name, trainable=trainable, literal_name=true)
        end
    finally
        pop!(scope_stack)
    end
    return v
end

type ConstantInitializer{T}
    value::T
end

function Base.rand(c::ConstantInitializer, shape...)
    fill(c.value, shape)
end
