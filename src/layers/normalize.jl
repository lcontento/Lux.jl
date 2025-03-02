abstract type AbstractNormalizationLayer{affine, track_stats} <: AbstractExplicitLayer end

has_affine(::AbstractNormalizationLayer{A, T}) where {A, T} = A
is_tracking_stats(::AbstractNormalizationLayer{A, T}) where {A, T} = T

CRC.@non_differentiable has_affine(::Any)
CRC.@non_differentiable is_tracking_stats(::Any)

@doc doc"""
    BatchNorm(chs::Integer, activation=identity; init_bias=zeros32, init_scale=ones32,
              affine=true, track_stats=true, epsilon=1f-5, momentum=0.1f0,
              allow_fast_activation::Bool=true)

[Batch Normalization](https://arxiv.org/abs/1502.03167) layer.

`BatchNorm` computes the mean and variance for each ``D_1 × ... × D_{N-2} × 1 × D_N`` input
slice and normalises the input accordingly.

## Arguments

  - `chs`: Size of the channel dimension in your data. Given an array with `N` dimensions,
    call the `N-1`th the channel dimension. For a batch of feature vectors this is
    just the data dimension, for `WHCN` images it's the usual channel dimension.
  - `activation`: After normalization, elementwise activation `activation` is applied.

## Keyword Arguments

  - If `track_stats=true`, accumulates mean and variance statistics in training phase that
    will be used to renormalize the input in test phase.

  - `epsilon`: a value added to the denominator for numerical stability
  - `momentum`:  the value used for the `running_mean` and `running_var` computation
  - `allow_fast_activation`: If `true`, then certain activations can be approximated with
    a faster version. The new activation function will be given by
    `NNlib.fast_act(activation)`
  - If `affine=true`, it also applies a shift and a rescale to the input through to
    learnable per-channel bias and scale parameters.

      + `init_bias`: Controls how the `bias` is initialized
      + `init_scale`: Controls how the `scale` is initialized

# Extended Help

## Inputs

  - `x`: Array where `size(x, N - 1) = chs` and `ndims(x) > 2`

## Returns

  - `y`: Normalized Array
  - Update model state

## Parameters

  - `affine=true`

      + `bias`: Bias of shape `(chs,)`
      + `scale`: Scale of shape `(chs,)`

  - `affine=false` - Empty `NamedTuple()`

## States

  - Statistics if `track_stats=true`

      + `running_mean`: Running mean of shape `(chs,)`
      + `running_var`: Running variance of shape `(chs,)`

  - Statistics if `track_stats=false`

      + `running_mean`: nothing
      + `running_var`: nothing
  - `training`: Used to check if training/inference mode

Use `Lux.testmode` during inference.

## Example

```jldoctest
julia> Chain(Dense(784 => 64), BatchNorm(64, relu), Dense(64 => 10), BatchNorm(10))
Chain(
    layer_1 = Dense(784 => 64),         # 50_240 parameters
    layer_2 = BatchNorm(64, relu, affine=true, track_stats=true),  # 128 parameters, plus 129
    layer_3 = Dense(64 => 10),          # 650 parameters
    layer_4 = BatchNorm(10, affine=true, track_stats=true),  # 20 parameters, plus 21
)         # Total: 51_038 parameters,
          #        plus 150 states.
```

!!! warning

    Passing a batch size of 1, during training will result in NaNs.

See also [`BatchNorm`](@ref), [`InstanceNorm`](@ref), [`LayerNorm`](@ref),
[`WeightNorm`](@ref)
"""
@concrete struct BatchNorm{affine, track_stats, N} <:
                 AbstractNormalizationLayer{affine, track_stats}
    activation
    epsilon::N
    momentum::N
    chs::Int
    init_bias
    init_scale
end

function BatchNorm(chs::Int, activation=identity; init_bias=zeros32,
        init_scale=ones32, affine::Bool=true, track_stats::Bool=true,
        epsilon=1.0f-5, momentum=0.1f0, allow_fast_activation::Bool=true)
    activation = allow_fast_activation ? NNlib.fast_act(activation) : activation
    return BatchNorm{affine, track_stats}(
        activation, epsilon, momentum, chs, init_bias, init_scale)
end

function initialparameters(rng::AbstractRNG, l::BatchNorm)
    if has_affine(l)
        return (scale=l.init_scale(rng, l.chs), bias=l.init_bias(rng, l.chs))
    else
        return NamedTuple()
    end
end

function initialstates(rng::AbstractRNG, l::BatchNorm)
    if is_tracking_stats(l)
        return (running_mean=zeros32(rng, l.chs),
            running_var=ones32(rng, l.chs), training=Val(true))
    else
        return (; training=Val(true))
    end
end

parameterlength(l::BatchNorm) = ifelse(has_affine(l), l.chs * 2, 0)
statelength(l::BatchNorm) = ifelse(is_tracking_stats(l), l.chs * 2, 0) + 1

function (BN::BatchNorm)(x::AbstractArray, ps, st::NamedTuple)
    CRC.ignore_derivatives() do
        if st.training isa Val{true}
            @argcheck size(x, ndims(x))!=1 "Batch size for BatchNorm cannot be 1 during training"
        end
    end

    getp = get_ops(:getproperty)

    x′ = match_eltype(BN, ps, st, x)
    y, stats = batchnorm(
        x′, getp(ps, Val(:scale)), getp(ps, Val(:bias)), getp(st, Val(:running_mean)),
        getp(st, Val(:running_var)), st.training, BN.activation, BN.momentum, BN.epsilon)
    return y, update_batchnorm_state(BN, st, stats)
end

function update_batchnorm_state(BN::BatchNorm, st::NamedTuple, stats)
    is_tracking_stats(BN) && return merge(st, (; stats.running_mean, stats.running_var))
    return st
end

CRC.@non_differentiable update_batchnorm_state(::Any...)

function Base.show(io::IO, l::BatchNorm)
    print(io, "BatchNorm($(l.chs)")
    (l.activation == identity) || print(io, ", $(l.activation)")
    print(io, ", affine=$(has_affine(l))")
    print(io, ", track_stats=$(is_tracking_stats(l))")
    return print(io, ")")
end

"""
    GroupNorm(chs::Integer, groups::Integer, activation=identity; init_bias=zeros32,
              init_scale=ones32, affine=true, epsilon=1f-5,
              allow_fast_activation::Bool=true)

[Group Normalization](https://arxiv.org/abs/1803.08494) layer.

## Arguments

  - `chs`: Size of the channel dimension in your data. Given an array with `N` dimensions,
    call the `N-1`th the channel dimension. For a batch of feature vectors this is
    just the data dimension, for `WHCN` images it's the usual channel dimension.
  - `groups` is the number of groups along which the statistics are computed. The number of
    channels must be an integer multiple of the number of groups.
  - `activation`: After normalization, elementwise activation `activation` is applied.

## Keyword Arguments

  - `epsilon`: a value added to the denominator for numerical stability

  - `allow_fast_activation`: If `true`, then certain activations can be approximated with
    a faster version. The new activation function will be given by
    `NNlib.fast_act(activation)`
  - If `affine=true`, it also applies  a shift and a rescale to the input through to
    learnable per-channel bias and scale parameters.

      + `init_bias`: Controls how the `bias` is initialized
      + `init_scale`: Controls how the `scale` is initialized

# Extended Help

## Inputs

  - `x`: Array where `size(x, N - 1) = chs` and `ndims(x) > 2`

## Returns

  - `y`: Normalized Array
  - Update model state

## Parameters

  - `affine=true`

      + `bias`: Bias of shape `(chs,)`
      + `scale`: Scale of shape `(chs,)`

  - `affine=false` - Empty `NamedTuple()`

## States

  - `training`: Used to check if training/inference mode

Use `Lux.testmode` during inference.

## Example

```jldoctest
julia> Chain(Dense(784 => 64), GroupNorm(64, 4, relu), Dense(64 => 10), GroupNorm(10, 5))
Chain(
    layer_1 = Dense(784 => 64),         # 50_240 parameters
    layer_2 = GroupNorm(64, 4, relu, affine=true),  # 128 parameters
    layer_3 = Dense(64 => 10),          # 650 parameters
    layer_4 = GroupNorm(10, 5, affine=true),  # 20 parameters
)         # Total: 51_038 parameters,
          #        plus 0 states.
```

See also [`GroupNorm`](@ref), [`InstanceNorm`](@ref), [`LayerNorm`](@ref),
[`WeightNorm`](@ref)
"""
@concrete struct GroupNorm{affine} <: AbstractNormalizationLayer{affine, false}
    activation
    epsilon
    chs::Int
    init_bias
    init_scale
    groups::Int
end

function GroupNorm(chs::Integer, groups::Integer, activation=identity; init_bias=zeros32,
        init_scale=ones32, affine=true, epsilon=1.0f-5, allow_fast_activation::Bool=true)
    @argcheck chs % groups==0 "The number of groups ($(groups)) must divide the number of channels ($chs)"
    activation = allow_fast_activation ? NNlib.fast_act(activation) : activation

    return GroupNorm{affine}(activation, epsilon, chs, init_bias, init_scale, groups)
end

function initialparameters(rng::AbstractRNG, l::GroupNorm)
    return has_affine(l) ? (scale=l.init_scale(rng, l.chs), bias=l.init_bias(rng, l.chs)) :
           (;)
end

parameterlength(l::GroupNorm) = has_affine(l) ? (l.chs * 2) : 0

function (GN::GroupNorm)(x::AbstractArray, ps, st::NamedTuple)
    x′ = match_eltype(GN, ps, st, x)
    y = groupnorm(x′, get_ops(:getproperty)(ps, Val(:scale)),
        get_ops(:getproperty)(ps, Val(:bias)), GN.groups, GN.activation, GN.epsilon)
    return y, st
end

function Base.show(io::IO, l::GroupNorm)
    print(io, "GroupNorm($(l.chs), $(l.groups)")
    (l.activation == identity) || print(io, ", $(l.activation)")
    print(io, ", affine=$(has_affine(l))")
    return print(io, ")")
end

@doc doc"""
    InstanceNorm(chs::Integer, activation=identity; init_bias=zeros32, init_scale=ones32,
                 affine=true, epsilon=1f-5, allow_fast_activation::Bool=true)

Instance Normalization. For details see [1].

Instance Normalization computes the mean and variance for each
``D_1 \times ... \times D_{N - 2} \times 1 \times 1``` input slice and normalises the input
accordingly.

## Arguments

  - `chs`: Size of the channel dimension in your data. Given an array with `N` dimensions,
    call the `N-1`th the channel dimension. For a batch of feature vectors this is
    just the data dimension, for `WHCN` images it's the usual channel dimension.
  - `activation`: After normalization, elementwise activation `activation` is applied.

## Keyword Arguments

  - `epsilon`: a value added to the denominator for numerical stability
  - `allow_fast_activation`: If `true`, then certain activations can be approximated with
    a faster version. The new activation function will be given by
    `NNlib.fast_act(activation)`
  - If `affine=true`, it also applies  a shift and a rescale to the input through to
    learnable per-channel bias and scale parameters.

      + `init_bias`: Controls how the `bias` is initialized
      + `init_scale`: Controls how the `scale` is initialized

## Inputs

  - `x`: Array where `size(x, N - 1) = chs` and `ndims(x) > 2`

## Returns

  - `y`: Normalized Array
  - Update model state

## Parameters

  - `affine=true`

      + `bias`: Bias of shape `(chs,)`
      + `scale`: Scale of shape `(chs,)`

  - `affine=false` - Empty `NamedTuple()`

## States

  - `training`: Used to check if training/inference mode

Use `Lux.testmode` during inference.

## Example

```jldoctest
julia> Chain(Dense(784 => 64), InstanceNorm(64, relu), Dense(64 => 10),
           InstanceNorm(10, relu))
Chain(
    layer_1 = Dense(784 => 64),         # 50_240 parameters
    layer_2 = InstanceNorm(64, relu, affine=true),  # 128 parameters, plus 1
    layer_3 = Dense(64 => 10),          # 650 parameters
    layer_4 = InstanceNorm(10, relu, affine=true),  # 20 parameters, plus 1
)         # Total: 51_038 parameters,
          #        plus 2 states.
```

## References

[1] Ulyanov, Dmitry, Andrea Vedaldi, and Victor Lempitsky. "Instance normalization: The
    missing ingredient for fast stylization." arXiv preprint arXiv:1607.08022 (2016).

See also [`BatchNorm`](@ref), [`GroupNorm`](@ref), [`LayerNorm`](@ref), [`WeightNorm`](@ref)
"""
@concrete struct InstanceNorm{affine} <: AbstractNormalizationLayer{affine, false}
    activation
    epsilon
    chs::Int
    init_bias
    init_scale
end

function InstanceNorm(
        chs::Integer, activation=identity; init_bias=zeros32, init_scale=ones32,
        affine=true, epsilon=1.0f-5, allow_fast_activation::Bool=true)
    activation = allow_fast_activation ? NNlib.fast_act(activation) : activation
    return InstanceNorm{affine}(activation, epsilon, chs, init_bias, init_scale)
end

function initialparameters(rng::AbstractRNG, l::InstanceNorm)
    if has_affine(l)
        return (scale=l.init_scale(rng, l.chs), bias=l.init_bias(rng, l.chs))
    else
        return (scale=nothing, bias=nothing)
    end
end

initialstates(::AbstractRNG, ::InstanceNorm) = (; training=Val(true))
parameterlength(l::InstanceNorm) = ifelse(has_affine(l), l.chs * 2, 0)

function (IN::InstanceNorm)(x::AbstractArray, ps, st::NamedTuple)
    x′ = match_eltype(IN, ps, st, x)
    y, _ = instancenorm(x′, get_ops(:getproperty)(ps, Val(:scale)),
        get_ops(:getproperty)(ps, Val(:bias)), st.training, IN.activation, IN.epsilon)
    return y, st
end

function Base.show(io::IO, l::InstanceNorm)
    print(io, "InstanceNorm($(l.chs)")
    (l.activation == identity) || print(io, ", $(l.activation)")
    print(io, ", affine=$(has_affine(l))")
    return print(io, ")")
end

@doc doc"""
    WeightNorm(layer::AbstractExplicitLayer, which_params::NTuple{N,Symbol},
               dims::Union{Tuple,Nothing}=nothing)

Applies [weight normalization](https://arxiv.org/abs/1602.07868) to a parameter in the given
layer.

```math
w = g\frac{v}{\|v\|}
```

Weight normalization is a reparameterization that decouples the magnitude of a weight tensor
from its direction. This updates the parameters in `which_params` (e.g. `weight`) using two
parameters: one specifying the magnitude (e.g. `weight_g`) and one specifying the direction
(e.g. `weight_v`).

## Arguments

  - `layer` whose parameters are being reparameterized
  - `which_params`: parameter names for the parameters being reparameterized
  - By default, a norm over the entire array is computed. Pass `dims` to modify the
    dimension.

## Inputs

  - `x`: Should be of valid type for input to `layer`

## Returns

  - Output from `layer`
  - Updated model state of `layer`

## Parameters

  - `normalized`: Parameters of `layer` that are being normalized
  - `unnormalized`: Parameters of `layer` that are not being normalized

## States

  - Same as that of `layer`
"""
@concrete struct WeightNorm{which_params, L <: AbstractExplicitLayer} <:
                 AbstractExplicitLayer
    layer::L
    dims
end

function WeightNorm{which_params}(layer::AbstractExplicitLayer;
        dims::Union{Tuple, Nothing}=nothing) where {which_params}
    return WeightNorm{which_params}(layer, dims)
end

function WeightNorm(layer::AbstractExplicitLayer, which_params::NTuple{N, Symbol},
        dims::Union{Tuple, Nothing}=nothing) where {N}
    return WeightNorm{which_params}(layer; dims)
end

function initialparameters(
        rng::AbstractRNG, wn::WeightNorm{which_params}) where {which_params}
    ps_layer = initialparameters(rng, wn.layer)
    ps_normalized = []
    ps_unnormalized = []
    i = 1
    for k in propertynames(ps_layer)
        v = ps_layer[k]
        if k in which_params
            if all(iszero, v)
                throw(ArgumentError("Parameter $(k) is completely zero. This will result \
                                     in NaN gradients. Either remove this parameter from \
                                     `which_params` or modify the initialization in the \
                                     actual layer. Typically this is controlled using the \
                                     `init_$(k)` keyword argument."))
            end
            dim = wn.dims === nothing ? ndims(v) : wn.dims[i]
            push!(ps_normalized, Symbol(string(k) * "_g") => Utils.norm_except(v; dims=dim))
            push!(ps_normalized, Symbol(string(k) * "_v") => v)
            i += 1
        else
            push!(ps_unnormalized, k => v)
        end
    end
    ps_unnormalized = length(ps_unnormalized) == 0 ? NamedTuple() : (; ps_unnormalized...)
    return (normalized=(; ps_normalized...), unnormalized=ps_unnormalized)
end

initialstates(rng::AbstractRNG, wn::WeightNorm) = initialstates(rng, wn.layer)

function (wn::WeightNorm)(x, ps, st::NamedTuple)
    y = match_eltype(wn, ps, st, x)
    psₙ = get_weight_normalized_parameters(wn, wn.dims, ps.normalized)
    return apply(wn.layer, y, Utils.merge(psₙ, ps.unnormalized), st)
end

@inbounds @generated function get_weight_normalized_parameters(
        ::WeightNorm{which_params}, dims::T, ps) where {T, which_params}
    parameter_names = string.(which_params)
    v_parameter_names = Symbol.(parameter_names .* "_v")
    g_parameter_names = Symbol.(parameter_names .* "_g")
    normalized_params_symbol = [gensym(p) for p in parameter_names]

    function get_norm_except_invoke(i)
        return if T <: Tuple
            :(Utils.norm_except(ps.$(v_parameter_names[i]); dims=dims[$i]))
        else
            :(Utils.norm_except(ps.$(v_parameter_names[i])))
        end
    end

    calls = []
    for i in 1:length(parameter_names)
        push!(calls,
            :($(normalized_params_symbol[i]) = ps.$(v_parameter_names[i]) .*
                                               (ps.$(g_parameter_names[i]) ./
                                                ($(get_norm_except_invoke(i)) .+
                                                 eps(eltype(ps.$(v_parameter_names[i])))))))
    end
    push!(calls,
        :(return NamedTuple{$(which_params)}(tuple($(Tuple(normalized_params_symbol)...)))))

    return Expr(:block, calls...)
end

function Base.show(io::IO, w::WeightNorm{which_params}) where {which_params}
    return print(io, "WeightNorm{", which_params, "}(", w.layer, ", dims = ", w.dims, ")")
end

@doc doc"""
    LayerNorm(shape::NTuple{N, Int}, activation=identity; epsilon=1f-5, dims=Colon(),
              affine::Bool=true, init_bias=zeros32, init_scale=ones32,)

Computes mean and standard deviation over the whole input array, and uses these to
normalize the whole array. Optionally applies an elementwise affine transformation
afterwards.

Given an input array ``x``, this layer computes

```math
y = \frac{x - \mathbb{E}[x]}{\sqrt{Var[x] + \epsilon}} * \gamma + \beta
```

where ``\gamma`` & ``\beta`` are trainable parameters if `affine=true`.

!!! warning "Inconsistent Defaults till v0.5.0"

    As of v0.5.0, the doc used to say `affine::Bool=false`, but the code actually had
    `affine::Bool=true` as the default. Now the doc reflects the code, so please check
    whether your assumptions about the default (if made) were invalid.

## Arguments

  - `shape`: Broadcastable shape of input array excluding the batch dimension.
  - `activation`: After normalization, elementwise activation `activation` is applied.

## Keyword Arguments

  - `allow_fast_activation`: If `true`, then certain activations can be approximated with
    a faster version. The new activation function will be given by
    `NNlib.fast_act(activation)`
  - `epsilon`: a value added to the denominator for numerical stability.
  - `dims`: Dimensions to normalize the array over.
  - If `affine=true`, it also applies  a shift and a rescale to the input through to
    learnable per-channel bias and scale parameters.

      + `init_bias`: Controls how the `bias` is initialized
      + `init_scale`: Controls how the `scale` is initialized

# Extended Help

## Inputs

  - `x`: AbstractArray

## Returns

  - `y`: Normalized Array
  - Empty NamedTuple()

## Parameters

  - `affine=false`: Empty `NamedTuple()`
  - `affine=true`

      + `bias`: Bias of shape `(shape..., 1)`
      + `scale`: Scale of shape `(shape..., 1)`
"""
@concrete struct LayerNorm{affine, N} <: AbstractNormalizationLayer{affine, false}
    shape::NTuple{N, Int}
    activation
    epsilon
    init_bias
    init_scale
    dims
end

function LayerNorm(shape::NTuple{N, <:Int}, activation=identity; epsilon::T=1.0f-5,
        dims=Colon(), affine::Bool=true, init_bias=zeros32,
        init_scale=ones32, allow_fast_activation::Bool=true) where {N, T}
    activation = allow_fast_activation ? NNlib.fast_act(activation) : activation
    return LayerNorm{affine, N}(shape, activation, epsilon, init_bias, init_scale, dims)
end

function initialparameters(rng::AbstractRNG, ln::LayerNorm)
    if has_affine(ln)
        return (bias=ln.init_bias(rng, ln.shape..., 1),
            scale=ln.init_scale(rng, ln.shape..., 1))
    else
        return NamedTuple()
    end
end

function (l::LayerNorm)(x::AbstractArray, ps, st::NamedTuple)
    x′ = match_eltype(l, ps, st, x)
    y = layernorm(x′, get_ops(:getproperty)(ps, Val(:scale)),
        get_ops(:getproperty)(ps, Val(:bias)), l.activation, l.dims, l.epsilon)
    return y, st
end

function Base.show(io::IO, l::LayerNorm)
    print(io, "LayerNorm($(l.shape)")
    (l.activation == identity) || print(io, ", $(l.activation)")
    print(io, ", affine=$(has_affine(l)), dims=$(l.dims)")
    return print(io, ")")
end
