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
    includes::Set{String} = Set{String}()
    function_defs::Set{String} = Set{String}()

    pending_imports::Set{Dep} = Set{Dep}()
    flat_usings::Set{String} = Set{String}()
    warns::Set{String} = Set{String}()
end

@enum Context begin
    TOP
    MODULE
    STRUCT
    FUNCTION
    FUNCTION_PARAMS
    FUNCTION_BODY
end

# `Dep` should only be constructed using this method
function mk_dep(root::AbstractString, unit::Symbol, f::Info)
    if startswith(root, ".") && LOAD_RELATIVE in CONF
        push!(f.warns, "$(f.name): Refrain from using relative paths in module names ($root)")
    end
    @assert !(isempty(root) && isempty(string(unit)))
    return Dep(root = root, unit = unit)
end

#####################################################

@enum ConfigOption begin
    ALL
    IMPORT_MULTIPLE
    LOAD_RELATIVE
    IMPORT_QUAL
    MODULE_DIR_NAME

    LOAD_INDIRECT
    LOAD_UNUSED
    USING_UNQUAL
    EXTEND_UNQUAL
    RETURN_IMPLICIT
    RETURN_COERSION
end

#####################################################

using DataStructures: Queue, Stack, enqueue!

const CONF = Set{ConfigOption}()
const CTX = Stack{Context}()
const FUNC_NAMES = Stack{String}()

function lint(options::Vector)
    empty!(CONF)
    union!(CONF, ALL in options ? instances(ConfigOption) : options)
    empty!(CTX)
    empty!(FUNC_NAMES)

    all_info = Dict{String, Info}()
    included_by = Dict{String, String}()

    for (base, dirs, files) in walkdir("src")
        for file in files
            endswith(file, ".jl") || continue

            path = joinpath(base, file)
            all_info[path] = f = Info(base_path = base, name = path)
            ast = Meta.parseall(read(path, String); filename = path)

            push!(CTX, TOP)
            _walk(ast, f)
            @assert first(CTX) == TOP
            pop!(CTX)

            for included_file in f.includes
                @assert !haskey(included_by, included_file)
                included_by[included_file] = f.name
            end
            for dep in f.usings
                dep.unit == DUMMY_SYM && continue
                push!(f.flat_usings, string(dep.unit))
            end
        end
    end

    for (fname, f) in all_info
        for dep in f.usings
            check_usage(dep, f, all_info, included_by, "using")
        end
        for dep in f.imports
            check_usage(dep, f, all_info, included_by, "import")
        end
        for dep in f.pending_imports
            check_defs(dep.root, string(dep.unit), f, all_info, "")
        end
        for func in f.function_defs
            check_extends(func, f, all_info, included_by, Queue{String}())
        end
    end

    total_warns = 0
    for (fname, f) in all_info
        for w in f.warns @warn w end
        total_warns += length(f.warns)
    end
    @info "Total Warnings: $total_warns"
end

include("walk.jl")
include("checks.jl")

end
