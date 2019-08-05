#
# Types supporting structural definition of models and their components
#

# Objects with a `name` attribute
@class NamedObj <: MimiClass begin
    name::Symbol
end

"""
    nameof(obj::NamedDef) = obj.name

Return the name of `def`.  `NamedDef`s include `DatumDef`, `ComponentDef`,
`CompositeComponentDef`, and `VariableDefReference` and `ParameterDefReference`.
"""
Base.nameof(obj::AbstractNamedObj) = obj.name

# TBD: old definition; should deprecate this...
name(obj::AbstractNamedObj) = obj.name

# Similar structure is used for variables and parameters (parameters merely adds `default`)
@class mutable DatumDef <: NamedObj begin
    comp_path::Union{Nothing, ComponentPath}
    datatype::DataType
    dim_names::Vector{Symbol}
    description::String
    unit::String
end

@class mutable VariableDef <: DatumDef

@class mutable ParameterDef <: DatumDef begin
    # ParameterDef adds a default value, which can be specified in @defcomp
    default::Any
end

@class mutable ComponentDef <: NamedObj begin
    comp_id::Union{Nothing, ComponentId}    # allow anonynous top-level (composite) ComponentDefs (must be referenced by a ModelDef)
    comp_path::Union{Nothing, ComponentPath}
    variables::OrderedDict{Symbol, VariableDef}
    parameters::OrderedDict{Symbol, ParameterDef}
    dim_dict::OrderedDict{Symbol, Union{Nothing, Dimension}}
    namespace::OrderedDict{Symbol, Any}
    first::Union{Nothing, Int}
    last::Union{Nothing, Int}
    is_uniform::Bool

    # Store a reference to the AbstractCompositeComponent that contains this comp def.
    # That type is defined later, so we declare Any here. Parent is `nothing` for
    # detached (i.e., "template") components and is set when added to a composite.
    parent::Any
    

    function ComponentDef(self::ComponentDef, comp_id::Nothing)
        error("Leaf ComponentDef objects must have a valid ComponentId name (not nothing)")
    end

    # ComponentDefs are created "empty". Elements are subsequently added.
    function ComponentDef(self::AbstractComponentDef, comp_id::Union{Nothing, ComponentId}=nothing;
                          name::Union{Nothing, Symbol}=nothing)
        if comp_id === nothing
            # ModelDefs are anonymous, but since they're gensym'd, they can claim the Mimi package
            comp_id = ComponentId(Mimi, @or(name, gensym(nameof(typeof(self)))))
        end

        name = @or(name, comp_id.comp_name)
        NamedObj(self, name)

        self.comp_id = comp_id
        self.comp_path = nothing    # this is set in add_comp!() and ModelDef()
        self.variables  = OrderedDict{Symbol, VariableDef}()
        self.parameters = OrderedDict{Symbol, ParameterDef}()
        self.dim_dict   = OrderedDict{Symbol, Union{Nothing, Dimension}}()
        self.namespace = OrderedDict{Symbol, Any}()
        self.first = self.last = nothing
        self.is_uniform = true
        self.parent = nothing
        return self
    end

    function ComponentDef(comp_id::Union{Nothing, ComponentId};
                          name::Union{Nothing, Symbol}=nothing)
        self = new()
        return ComponentDef(self, comp_id; name=name)
    end
end

ns(obj::AbstractComponentDef) = obj.namespace
comp_id(obj::AbstractComponentDef) = obj.comp_id
pathof(obj::AbstractComponentDef) = obj.comp_path
dim_dict(obj::AbstractComponentDef) = obj.dim_dict
first_period(obj::AbstractComponentDef) = obj.first
last_period(obj::AbstractComponentDef) = obj.last
isuniform(obj::AbstractComponentDef) = obj.is_uniform

Base.parent(obj::AbstractComponentDef) = obj.parent

# Used by @defcomposite to communicate subcomponent information
struct SubComponent <: MimiStruct
    module_name::Union{Nothing, Symbol}
    comp_name::Symbol
    alias::Union{Nothing, Symbol}
    exports::Vector{Union{Symbol, Pair{Symbol, Symbol}}}
    bindings::Vector{Pair{Symbol, Any}}
end

# Stores references to the name of a component variable or parameter
# and the ComponentPath of the component in which it is defined
@class DatumReference <: NamedObj begin
    # name::Symbol is inherited from NamedObj
    root::AbstractComponentDef
    comp_path::ComponentPath
end

@class ParameterDefReference <: DatumReference

@class VariableDefReference  <: DatumReference

function datum_reference(comp::ComponentDef, datum_name::Symbol)
    root = get_root(comp)
    
    # @info "compid: $(comp.comp_id)"
    # @info "datum_reference: comp path: $(printable(comp.comp_path)) parent: $(printable(comp.parent))"

    if has_variable(comp, datum_name)
        var = comp.variables[datum_name]
        path = @or(var.comp_path, ComponentPath(comp.name))
        # @info "   var path: $path)"
        return VariableDefReference(datum_name, root, path)
    end
    
    if has_parameter(comp, datum_name)
        par = comp.parameters[datum_name]
        path = @or(par.comp_path, ComponentPath(comp.name))
        # @info "   par path: $path)"
        return ParameterDefReference(datum_name, root, path)
    end

    error("Component $(comp.comp_id) does not have a data item named :$datum_name")
end

# Define type aliases to avoid repeating these in several places
global const Binding = Pair{AbstractDatumReference, Union{Int, Float64, AbstractDatumReference}}
global const ExportsDict = Dict{Symbol, AbstractDatumReference}

global const NamespaceElement = Union{AbstractComponentDef, VariableDefReference, Vector{ParameterDefReference}}

@class mutable CompositeComponentDef <: ComponentDef begin
    #comps_dict::OrderedDict{Symbol, AbstractComponentDef}
    bindings::Vector{Binding}
    exports::ExportsDict

    internal_param_conns::Vector{InternalParameterConnection}
    external_param_conns::Vector{ExternalParameterConnection}
    external_params::Dict{Symbol, ModelParameter}               # TBD: make key (ComponentPath, Symbol)?

    # Names of external params that the ConnectorComps will use as their :input2 parameters.
    backups::Vector{Symbol}

    sorted_comps::Union{Nothing, Vector{Symbol}}

    function CompositeComponentDef(comp_id::Union{Nothing, ComponentId}=nothing)
        self = new()
        CompositeComponentDef(self, comp_id)
        return self
    end

    function CompositeComponentDef(self::AbstractCompositeComponentDef, comp_id::Union{Nothing, ComponentId}=nothing)
        ComponentDef(self, comp_id) # call superclass' initializer

        self.comp_path = ComponentPath(self.name)
        # self.comps_dict = OrderedDict{Symbol, AbstractComponentDef}()
        self.bindings = Vector{Binding}()
        self.exports  = ExportsDict()
        self.internal_param_conns = Vector{InternalParameterConnection}()
        self.external_param_conns = Vector{ExternalParameterConnection}()
        self.external_params = Dict{Symbol, ModelParameter}()
        self.backups = Vector{Symbol}()
        self.sorted_comps = nothing
    end
end

# Used by @defcomposite
function CompositeComponentDef(comp_id::ComponentId, alias::Symbol, subcomps::Vector{SubComponent}, 
                               calling_module::Module)
    # @info "CompositeComponentDef($comp_id, $alias, $subcomps)"
    composite = CompositeComponentDef(comp_id)

    for c in subcomps
        # @info "subcomp $c: module_name: $(printable(c.module_name)), calling module: $(nameof(calling_module))"
        comp_name = @or(c.module_name, nameof(calling_module))
        subcomp_id = ComponentId(comp_name, c.comp_name)
        # @info "subcomp_id: $subcomp_id"
        subcomp = compdef(subcomp_id, module_obj=(c.module_name === nothing ? calling_module : nothing))

        # x = printable(subcomp === nothing ? nothing : subcomp_id)
        # y = printable(composite === nothing ? nothing : comp_id)
        # @info "CompositeComponentDef calling add_comp!($y, $x)"

        add_comp!(composite, subcomp, @or(c.alias, c.comp_name), exports=c.exports)
    end
    return composite
end

# TBD: Recursively compute the lists on demand?
internal_param_conns(obj::AbstractCompositeComponentDef) = obj.internal_param_conns
external_param_conns(obj::AbstractCompositeComponentDef) = obj.external_param_conns

external_params(obj::AbstractCompositeComponentDef) = obj.external_params

exported_names(obj::AbstractCompositeComponentDef) = keys(obj.exports)
is_exported(obj::AbstractCompositeComponentDef, name::Symbol) = haskey(obj.exports, name)

add_backup!(obj::AbstractCompositeComponentDef, backup) = push!(obj.backups, backup)

is_leaf(c::AbstractComponentDef) = true
is_leaf(c::AbstractCompositeComponentDef) = false
is_composite(c::AbstractComponentDef) = !is_leaf(c)

ComponentPath(obj::AbstractCompositeComponentDef, name::Symbol) = ComponentPath(obj.comp_path, name)

ComponentPath(obj::AbstractCompositeComponentDef, path::AbstractString) = comp_path(obj, path)

ComponentPath(obj::AbstractCompositeComponentDef, names::Symbol...) = ComponentPath(obj.comp_path.names..., names...)

@class mutable ModelDef <: CompositeComponentDef begin
    number_type::DataType
    dirty::Bool

    function ModelDef(number_type::DataType=Float64)
        self = new()
        CompositeComponentDef(self)  # call super's initializer
        return ModelDef(self, number_type, false)       # call @class-generated method
    end
end

#
# Reference types offer a more convenient syntax for interrogating Components.
#

# A container for a component, for interacting with it within a model.
@class ComponentReference <: MimiClass begin
    parent::AbstractComponentDef
    comp_path::ComponentPath
end

function ComponentReference(parent::AbstractComponentDef, name::Symbol)
    return ComponentReference(parent, ComponentPath(parent.comp_path, name))
end

# A container for a variable within a component, to improve connect_param! aesthetics,
# by supporting subscripting notation via getindex & setindex .
@class VariableReference <: ComponentReference begin
    var_name::Symbol
end
