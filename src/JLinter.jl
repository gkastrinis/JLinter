module JLinter

const DUMMY_SYM = Symbol("")

# `import`/`using` $root: $unit...
Base.@kwdef struct Dep
    root::String
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
    mod::Symbol = DUMMY_SYM
    symbols::Set{Symbol} = Set{Symbol}()
    mods::Set{Symbol} = Set{Symbol}()
    imports::Set{Dep} = Set{Dep}()
    usings::Set{Dep} = Set{Dep}()
    exports::Set{Symbol} = Set{Symbol}()
    includes::Vector{String} = Vector{String}()
end

@enum ConfigOption begin
    LOAD_INDIRECT
    LOAD_UNUSED
    LOAD_RELATIVE
    IMPORT_MULTIPLE
    IMPORT_QUAL
    USING_UNQUAL
    MODULE_DIR_NAME
    RETURN_IMPLICIT
end

#####################################################

# TODO isnothing etc
# TODO return type coersion

const CONF = Set{ConfigOption}()

function lint(options::Vector)
    union!(CONF, options)

    all_info = Dict{String, Info}()
    included_by = Dict{String, String}()

    for (base, dirs, files) in walkdir("src")
        for file in files
            endswith(file, ".jl") || continue

            path = joinpath(base, file)
            all_info[path] = f = Info(base_path = base, name = path)
            ast = Meta.parseall(read(path, String); filename = path)
            _walk(ast, f)
            dump(ast.args[4].args[4].args[3].args[3])

            for included_file in f.includes
                @assert !haskey(included_by, included_file)
                included_by[included_file] = f.name
            end
        end
    end

    check = (dep::Dep, f::Info, kind::String) -> begin
        # `using`/`import` X: bar -> ... `bar`
        # `using`/`import` X -> ... `X`
        found = _find(dep, f, all_info)
        if !found && haskey(included_by, f.name)
            parent_info = all_info[included_by[f.name]]
            found = _find(dep, parent_info, all_info)
            if found && LOAD_INDIRECT in CONF
                @warn "($(f.name)): `$kind $dep` used indirectly"
            end
        end
        if !found && LOAD_UNUSED in CONF
            @warn "($(f.name)): `$kind $dep` unused"
        end
    end

    for (fname, f) in all_info
        for dep in f.usings check(dep, f, "using") end
        for dep in f.imports check(dep, f, "import") end
    end
end


function _find(dep::Dep, f::Info, all_info)
    filter = (dep.unit == DUMMY_SYM ? last(split(dep.root, ".")) : dep.unit)
    (filter in f.symbols) && return true

    for included_file in f.includes
        haskey(all_info, included_file) || continue
        included_info = all_info[included_file]
        _find(dep, included_info, all_info) && return true
    end
    return false
end

function mk_dep(root::String, unit::Symbol, f::Info)
    if startswith(root, ".") && LOAD_RELATIVE in CONF
        @warn "$(f.name): Refrain from using relative paths in module names ($root)"
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
        root = _join(base.args[1].args)
        units = @view base.args[2:end]
        for arg in units
            @assert arg.head == Symbol(".")
            @assert length(arg.args) == 1
            push!(collection, mk_dep(root, Symbol(_join(arg.args)), f))
        end
        if e.head == :import && IMPORT_QUAL in CONF
            @warn "$(f.name): Refrain from using qualified `import` ($root $(_str(units)))"
        end
    else
        if e.head == :using && USING_UNQUAL in CONF
            @warn "$(f.name): Refrain from using unqualified `using` ($(_str(e.args)))"
        end
        if length(e.args) > 1 && IMPORT_MULTIPLE in CONF
            @warn "$(f.name): Unqualified `import` has multiple IDs ($(_str(e.args))) in one line"
        end
        for arg in e.args
            @assert arg.head == Symbol(".")
            push!(collection, mk_dep(_join(arg.args), DUMMY_SYM, f))
        end
    end
end

function _walk(e::Expr, f::Info)
    @assert e.head isa Symbol
    if e.head == :module
        @assert e.args[1] == true
        @assert e.args[3] isa Expr
        @assert length(e.args) == 3
        @assert f.mod == DUMMY_SYM

        push!(f.mods, e.args[2])
        f.mod = e.args[2]
        _walk(e.args, f)

        parent_dir = splitpath(f.name)[end-1]
        if parent_dir != "src" && parent_dir != string(f.mod) && MODULE_DIR_NAME in CONF
            @warn "$(f.name): Module `$(f.mod)` doesn't match parent directory name (`$parent_dir`)"
        end
    # NOTE: a short form function definition has "=" as the head symbol
    elseif e.head == :function
        # It has a non-trivial body
        if length(e.args) > 1
            name = e.args[1].args[1]
            @assert e.args[2].head == :block
            l = last(e.args[2].args)
            if !(l isa Expr && l.head == :return) && RETURN_IMPLICIT in CONF
                @warn "$(f.name): Explicit `return` missing in `$name`"
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

end
