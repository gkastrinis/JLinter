module JLinter

const DUMMY_SYM = Symbol("")

Base.@kwdef struct Dep
    root::Symbol
    unit::Symbol
end

function Base.show(io::IO, dep::Dep)
    print(io, dep.root)
    dep.unit == DUMMY_SYM && return
    print(io, ".")
    print(io, dep.unit)
end

Base.@kwdef mutable struct Info
    base_path::String
    name::String
    symbols::Set{Symbol} = Set{Symbol}()
    mods::Set{Symbol} = Set{Symbol}()
    imports::Set{Dep} = Set{Dep}()
    usings::Set{Dep} = Set{Dep}()
    exports::Set{Symbol} = Set{Symbol}()
    includes::Vector{String} = Vector{String}()

    curr_mod::Symbol = DUMMY_SYM
    curr_fun::Symbol = DUMMY_SYM
end


function lint()
    all_info = Dict{String, Info}()

    for (base, dirs, files) in walkdir("src")
        for file in files
            endswith(file, ".jl") || continue
            path = joinpath(base, file)
            # base = "src"
            # path = "src/Main.jl"
            # @info "Parsing $path..."
            all_info[path] = f = Info(base_path = base, name = path)
            ast = Meta.parseall(read(path, String); filename = path)
            _walk(ast, f)
        end
    end

    for (fname, f) in all_info
        for dep in f.usings
            _find(dep, f, all_info) #|| @warn "($(f.name)): `using $dep` unused"
        end
    end
end


function mk_dep(root::Symbol, unit::Symbol, f::Info)
    if startswith(string(root), ".")
        # @warn "$(f.name): Refrain from using relative paths in module names ($root)"
    end
    return Dep(root = root, unit = unit)
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
        # `import`/`using` $root: $unit...
        root = _sym(base.args[1].args)
        units = @view base.args[2:end]
        for arg in units
            @assert arg.head == Symbol(".")
            @assert length(arg.args) == 1
            push!(collection, mk_dep(root, _sym(arg.args), f))
        end
        if e.head == :import
            # @warn "$(f.name): Refrain from using qualified `import` ($root $(_str(units)))"
        end
    else
        if e.head == :using
            # @warn "$(f.name): Refrain from using unqualified `using` ($(_str(e.args)))"
        end
        if length(e.args) > 1
            # @warn "$(f.name): Unqualified `import` has multiple IDs ($(_str(e.args))) in one line"
        end
        for arg in e.args
            @assert arg.head == Symbol(".")
            push!(collection, mk_dep(_sym(arg.args), DUMMY_SYM, f))
        end
    end
end

function _walk(e::Expr, f::Info)
    @assert e.head isa Symbol
    if e.head == :module
        @assert e.args[1] == true
        @assert e.args[3] isa Expr
        @assert length(e.args) == 3
        @assert f.curr_mod == DUMMY_SYM

        push!(f.mods, e.args[2])
        f.curr_mod = e.args[2]
        _walk(e.args, f)

        parent_dir = splitpath(f.name)[end-1]
        if parent_dir != "src" && parent_dir != string(f.curr_mod)
            # @warn "Module `$(f.curr_mod)` doesn't match parent directory name (`$parent_dir`)"
        end

        f.curr_mod = DUMMY_SYM
    elseif e.head == :function
        # It has a non-trivial body
        if length(e.args) > 1
            name = e.args[1].args[1]
            @assert e.args[2].head == :block
            l = last(e.args[2].args)
            if !(l isa Expr && l.head == :return)
                # @warn "Explicit `return` missing in `$name`"
            end
        end
        _walk(e.args, f)
    elseif e.head == :import
        _load(e, f.imports, f)
        return
    elseif e.head == :using
        _load(e, f.usings, f)
        return
    elseif e.head == :export
        union!(f.exports, e.args)
    elseif e.head == :call && e.args[1] == :include

        push!(f.includes, joinpath(f.base_path, e.args[2]))
    else
        _walk(e.args, f)
    end
    return nothing
end

_walk(s::Symbol, f::Info) = _add_sym(s, f.symbols)

_walk(args::Array, f::Info) = for arg in args _walk(arg, f) end

const valid_global = Set{Symbol}([Symbol("@doc"), Symbol("@cmd")])

function _walk(ref::GlobalRef, f::Info)
    @assert ref.mod == Core
    @assert ref.name in valid_global
    return nothing
end

_walk(l::LineNumberNode, f::Info) = nothing

function _walk(q::QuoteNode, f::Info)
    q.value isa Symbol || return
    _add_sym(q.value, f.symbols)
end

_walk(a, f::Info) = nothing

_sym(args::Array) = Symbol(reduce((x, y) -> begin string(x) * string(y) end, args))

_sym(e::Expr) = _sym(e.args)

_sym(s::AbstractString) = Symbol(s)

function _str(args::AbstractArray)
    length(args) == 1 && return string(_sym(args[1].args))
    reduce((x, y) -> begin string(_sym(x)) * ", " * string(_sym(y)) end, args)
end

const to_skip = Set{Symbol}([
    Symbol("@__DIR__"), Symbol("@v_str"), Symbol("@warn"), :nothing,
    Symbol("="), Symbol("<"), Symbol("=="), Symbol("≈"), Symbol("≥"),
    Symbol("+"), Symbol("-"), Symbol("*"), Symbol("/"), Symbol("%"), Symbol("!"),
    Symbol(">>"), Symbol("<<"), Symbol("=>"), Symbol("~"), Symbol("^"), Symbol("÷"),
    Symbol("|"), Symbol("&"), Symbol("||"), Symbol("&&"), Symbol(".+"), Symbol(".!"),
    Symbol("⊆"), Symbol("⊇"), Symbol("≤"), Symbol("⊔"), Symbol("⊓"),
    Symbol("∉"), Symbol("∈"), :in, Symbol("∧"), Symbol("∨"), Symbol("∩"), Symbol("∪"),
    Symbol("Int"), Symbol("Int64"), Symbol("Float"), Symbol("Float64"),
    Symbol("./"), Symbol(".=>"), Symbol("."), Symbol(":"), Symbol("::"), Symbol("\$"),
])

function _add_sym(s::Symbol, set::Set{Symbol})
    s in to_skip && return
    push!(set, s)
end

# `using`/`import` X: bar -> ... `bar`
# `using`/`import` X -> ... `X`
function _find(dep::Dep, f::Info, all_info)
    filter = (dep.unit == DUMMY_SYM ? dep.root : dep.unit)
    (filter in f.symbols) && return true

    for included_file in f.includes
        included_info = all_info[included_file]
        found = _find(dep, included_info, all_info)
        found && return true
    end
    return false
end


end
