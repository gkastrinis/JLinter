function is_function_def(e::Expr)
    e.head == :macro && return true
    e.head == :function && return true
    # A short form function definition has "=" as the head symbol
    e.head == Symbol("=") || return false
    length(e.args) == 2 || return false
    (e.args[1] isa Expr && e.args[2] isa Expr) || return false
    e.args[2].head == :block || return false

    return first(CTX) != STRUCT && first(CTX) != FUNCTION_BODY
end

function _walk(e::Expr, f::Info)
    @assert e.head isa Symbol

    if e.head == :module
        push!(CTX, MODULE)
        _walk_mod(e, f)
        pop!(CTX)
    elseif e.head == :struct
        push!(CTX, STRUCT)
        _walk(e.args, f)
        pop!(CTX)
    elseif is_function_def(e)
        # `function foo end`
        if length(e.args) == 1
            push!(f.function_defs, string(e.args[1]))
        else
            @assert length(e.args) == 2

            push!(CTX, FUNCTION)
            _walk(e.args, f)

            l = last(e.args[2].args)
            if !(l isa Expr && l.head == :return) && RETURN_IMPLICIT in CONF
                push!(f.warns, "$(f.name): Explicit `return` missing in `$(first(FUNC_NAMES))`")
            end

            pop!(FUNC_NAMES)
            pop!(CTX)
        end
    elseif (e.head == :parameters || e.head == :kw) && first(CTX) == FUNCTION
        push!(CTX, FUNCTION_PARAMS)
        _walk(e.args, f)
        pop!(CTX)
    # Function definitions are calls in the AST
    # Need to differentiate from normal method calls
    elseif e.head == :call && first(CTX) == FUNCTION
        fname = _find_function_name(e, f)
        push!(f.function_defs, fname)
        push!(FUNC_NAMES, fname)
        _walk(e.args, f)
    elseif e.head == Symbol("::")
        if first(CTX) == FUNCTION && e.args[1] isa Expr && e.args[1].head == :call && RETURN_COERSION in CONF
            push!(f.warns, "$(f.name): Return-type annotation in `$(first(FUNC_NAMES))` is a type-coersion")
        end
        _walk(e.args, f)
    elseif e.head == :block && first(CTX) == FUNCTION
        push!(CTX, FUNCTION_BODY)
        _walk(e.args, f)
        pop!(CTX)
    elseif e.head == :import
        _load(e, f.imports, f)
    elseif e.head == :using
        _load(e, f.usings, f)
    elseif e.head == :export
        union!(f.exports, e.args)
    elseif e.head == :call && e.args[1] == :include
        push!(f.includes, joinpath(f.base_path, e.args[2]))
    else
        _walk(e.args, f)
    end
end

_walk(s::Symbol, f::Info) = push!(f.symbols, s)

_walk(args::Array, f::Info) = for arg in args _walk(arg, f) end

function _walk(ref::GlobalRef, f::Info)
    @assert ref.mod == Core
    @assert ref.name in [Symbol("@doc"), Symbol("@cmd")]
    return nothing
end

_walk(l::LineNumberNode, f::Info) = nothing

function _walk(q::QuoteNode, f::Info)
    q.value isa Symbol || return
    push!(f.symbols, q.value)
end

_walk(a, f::Info) = nothing

function _walk_mod(e::Expr, f::Info)
    @assert e.args[1] == true
    @assert e.args[3] isa Expr
    @assert length(e.args) == 3
    @assert f.mod == DUMMY_SYM

    push!(f.mods, e.args[2])
    f.mod = e.args[2]

    _walk(e.args, f)

    parent_dir = splitpath(f.name)[end-1]
    if parent_dir != "src" && parent_dir != string(f.mod) && MODULE_DIR_NAME in CONF
        push!(f.warns, "$(f.name): Module `$(f.mod)` doesn't match parent directory name (`$parent_dir`)")
    end
end

function _join(args::Array)
    length(args) == 1 && return string(args[1])
    foldl((x, y) -> begin
        str_x = string(x)
        str_y = string(y)
        startswith(str_x, ".") && return str_x * str_y
        return str_x * "." * str_y
    end, args)
end

_join(e::Expr) = _join(e.args)

_join(e::AbstractString) = e

function _str(args::AbstractArray)
    length(args) == 1 && return _join(args[1].args)
    reduce((x, y) -> begin _join(x) * ", " * _join(y) end, args)
end

function _find_function_name(e::Expr, f::Info)
    name = e.args[1]
    name = (name isa Expr && name.head == :curly) ? name.args[1] : name
    # Check that `name` is a complex expression (e.g., Foo.bar)
    if name isa Expr && name.head == Symbol(".")
        return string(name.args[1]) * "." * string(name.args[2].value)
    elseif name isa Symbol
        return string(name)
    else
        # @warn "What"
    end
    return ""
end

# import Foo OK
# using Foo: bar OK
# using Foo NOT
# import Foo: bar NOT
# import Foo, Bar NOT
function _load(e::Expr, collection::Set{Dep}, f::Info)
    if e.args[1].head == Symbol(":")
        @assert length(e.args) == 1
        base = e.args[1]
        root = _join(base.args[1].args)
        units = @view base.args[2:end]
        for arg in units
            @assert arg.head == Symbol(".")
            @assert length(arg.args) == 1
            push!(collection, mk_dep(root, Symbol(_join(arg.args)), f))
        end
        if e.head == :import && IMPORT_QUAL in CONF
            for unit in units
                @assert length(unit.args) == 1
                push!(f.pending_imports, mk_dep(split(root, ".")[end], unit.args[1], f))
            end
        end
    else
        if e.head == :using && USING_UNQUAL in CONF
            push!(f.warns, "$(f.name): Refrain from using unqualified `using` ($(_str(e.args)))")
        end
        if length(e.args) > 1 && IMPORT_MULTIPLE in CONF
            push!(f.warns, "$(f.name): Unqualified `import` has multiple IDs ($(_str(e.args))) in one line")
        end
        for arg in e.args
            @assert arg.head == Symbol(".")
            push!(collection, mk_dep(_join(arg.args), DUMMY_SYM, f))
        end
    end
end
