function check_usage(dep::Dep, f::Info, all_info::Dict{String, Info}, included_by::Dict{String, String}, kind::String)
    # `using`/`import` X: bar -> ... `bar`
    # `using`/`import` X -> ... `X`
    found = _find_use(dep, f, all_info)
    if !found
        # Backwards check in parent file
        if haskey(included_by, f.name)
            parent_info = all_info[included_by[f.name]]
            found = _find_use(dep, parent_info, all_info)
            if found && LOAD_INDIRECT in CONF
                push!(f.warns, "($(f.name)): `$kind $dep` used indirectly")
            end
        end

        LOAD_UNUSED in CONF && push!(f.warns, "($(f.name)): `$kind $dep` unused")
    end
end

function _find_use(dep::Dep, f::Info, all_info)
    filter = (dep.unit == DUMMY_SYM ? last(split(dep.root, ".")) : dep.unit)
    (filter in f.symbols) && return true

    for included_file in f.includes
        haskey(all_info, included_file) || continue
        included_info = all_info[included_file]
        _find_use(dep, included_info, all_info) && return true
    end
    return false
end


function check_defs(dep::Dep, f::Info, all_info::Dict{String, Info}, included_by::Dict{String, String})
    found = _find_def(dep.root, string(dep.unit), f, all_info, "")
    if !found && IMPORT_QUAL in CONF
        push!(f.warns, "$(f.name): Refrain from using qualified `import` ($dep)")
    end
end

# TODO identify unqualified method extensions
function _find_def(root::String, unit::String, f::Info, all_info, parent::String)
    suffix = isempty(parent) ? "" : " -- from: $parent"
    # First search for defining `X.foo`
    if !isempty(root) && (root * "." * unit) in f.function_defs
        push!(f.warns, "$(f.name): Qualified extension of method (`$root.$unit`)$suffix")
        return true
    end
    # Then for defining `foo` alone
    if unit in f.function_defs
        maybe_root = isempty(root) ? "" : " -- $root"
        push!(f.warns, "$(f.name): Unqualified extension of method (`$unit`$maybe_root)$suffix")
        return true
    end

    for included_file in f.includes
        haskey(all_info, included_file) || continue
        included_info = all_info[included_file]
        _find_def(root, unit, included_info, all_info, f.name) && return true
    end
    return false
end
