# Error for aliases used in recipes
function warn_on_recipe_aliases!(plotattributes, recipe_type, args...)
    for k in keys(plotattributes)
        if !is_default_attribute(k)
            dk = get(_keyAliases, k, k)
            if k !== dk
                @warn "Attribute alias `$k` detected in the $recipe_type recipe defined for the signature $(signature_string(Val{recipe_type}, args...)). To ensure expected behavior it is recommended to use the default attribute `$dk`."
            end
            plotattributes[dk] = pop_kw!(plotattributes, k)
        end
    end
end
warn_on_recipe_aliases!(v::AbstractVector, recipe_type, args) =
    foreach(x -> warn_on_recipe_aliases!(x, recipe_type, args), v)
warn_on_recipe_aliases!(rd::RecipeData, recipe_type, args) =
    warn_on_recipe_aliases!(rd.plotattributes, recipe_type, args)

function signature_string(::Type{Val{:user}}, args...)
    return string("(::", join(string.(typeof.(args)), ", ::"), ")")
end
signature_string(::Type{Val{:type}}, T) = "(::Type{$T}, ::$T)"
signature_string(::Type{Val{:plot}}, st) = "(::Type{Val{:$st}}, ::AbstractPlot)"
signature_string(::Type{Val{:series}}, st) = "(::Type{Val{:$st}}, x, y, z)"

# ------------------------------------------------------------------
# preprocessing

function series_idx(kw_list::AVec{KW}, kw::AKW)
    Int(kw[:series_plotindex]) - Int(kw_list[1][:series_plotindex]) + 1
end

function _expand_seriestype_array(plotattributes::AKW, args)
    sts = get(plotattributes, :seriestype, :path)
    if typeof(sts) <: AbstractArray
        reset_kw!(plotattributes, :seriestype)
        rd = Vector{RecipeData}(undef, size(sts, 1))
        for r in axes(sts, 1)
            dc = copy(plotattributes)
            dc[:seriestype] = sts[r:r,:]
            rd[r] = RecipeData(dc, args)
        end
        rd
    else
        RecipeData[RecipeData(copy(plotattributes), args)]
    end
end

function _preprocess_args(plotattributes::AKW, args, still_to_process::Vector{RecipeData})
    # the grouping mechanism is a recipe on a GroupBy object
    # we simply add the GroupBy object to the front of the args list to allow
    # the recipe to be applied
    if haskey(plotattributes, :group)
        args = (extractGroupArgs(plotattributes[:group], args...), args...)
    end

    # if we were passed a vector/matrix of seriestypes and there's more than one row,
    # we want to duplicate the inputs, once for each seriestype row.
    if !isempty(args)
        append!(still_to_process, _expand_seriestype_array(plotattributes, args))
    end

    # remove subplot and axis args from plotattributes... they will be passed through in the kw_list
    if !isempty(args)
        for (k,v) in plotattributes
            for defdict in (_subplot_defaults,
                            _axis_defaults,
                            _axis_defaults_byletter[:x],
                            _axis_defaults_byletter[:y],
                            _axis_defaults_byletter[:z])
                if haskey(defdict, k)
                    reset_kw!(plotattributes, k)
                end
            end
        end
    end

    args
end

# ------------------------------------------------------------------
# user recipes


function _process_userrecipes(plt::Plot, plotattributes::AKW, args)
    still_to_process = RecipeData[]
    args = _preprocess_args(plotattributes, args, still_to_process)

    # for plotting recipes, swap out the args and update the parameter dictionary
    # we are keeping a stack of series that still need to be processed.
    # each pass through the loop, we pop one off and apply the recipe.
    # the recipe will return a list a Series objects... the ones that are
    # finished (no more args) get added to the kw_list, the ones that are not
    # are placed on top of the stack and are then processed further.
    kw_list = KW[]
    while !isempty(still_to_process)
        # grab the first in line to be processed and either add it to the kw_list or
        # pass it through apply_recipe to generate a list of RecipeData objects (data + attributes)
        # for further processing.
        next_series = popfirst!(still_to_process)
        # recipedata should be of type RecipeData.  if it's not then the inputs must not have been fully processed by recipes
        if !(typeof(next_series) <: RecipeData)
            error("Inputs couldn't be processed... expected RecipeData but got: $next_series")
        end
        if isempty(next_series.args)
            _process_userrecipe(plt, kw_list, next_series)
        else
            rd_list = RecipesBase.apply_recipe(
                next_series.plotattributes,
                next_series.args...
            )
            warn_on_recipe_aliases!(rd_list, :user, next_series.args)
            prepend!(still_to_process,rd_list)
        end
    end

    # don't allow something else to handle it
    plotattributes[:smooth] = false
    kw_list
end

function _process_userrecipe(plt::Plot, kw_list::Vector{KW}, recipedata::RecipeData)
    # when the arg tuple is empty, that means there's nothing left to recursively
    # process... finish up and add to the kw_list
    kw = recipedata.plotattributes
    preprocessArgs!(kw)
    _preprocess_userrecipe(kw)
    warnOnUnsupported_scales(plt.backend, kw)

    # add the plot index
    plt.n += 1
    kw[:series_plotindex] = plt.n

    push!(kw_list, kw)
    _add_errorbar_kw(kw_list, kw)
    _add_smooth_kw(kw_list, kw)
    return
end

function _preprocess_userrecipe(kw::AKW)
    _add_markershape(kw)

    # if there was a grouping, filter the data here
    _filter_input_data!(kw)

    # map marker_z if it's a Function
    if isa(get(kw, :marker_z, nothing), Function)
        # TODO: should this take y and/or z as arguments?
        kw[:marker_z] = isa(kw[:z], Nothing) ? map(kw[:marker_z], kw[:x], kw[:y]) : map(kw[:marker_z], kw[:x], kw[:y], kw[:z])
    end

    # map line_z if it's a Function
    if isa(get(kw, :line_z, nothing), Function)
        kw[:line_z] = isa(kw[:z], Nothing) ? map(kw[:line_z], kw[:x], kw[:y]) : map(kw[:line_z], kw[:x], kw[:y], kw[:z])
    end

    # convert a ribbon into a fillrange
    if get(kw, :ribbon, nothing) !== nothing
        make_fillrange_from_ribbon(kw)
    end
    return
end

function _add_errorbar_kw(kw_list::Vector{KW}, kw::AKW)
    # handle error bars by creating new recipedata data... these will have
    # the same recipedata index as the recipedata they are copied from
    for esym in (:xerror, :yerror)
        if get(kw, esym, nothing) !== nothing
            # we make a copy of the KW and apply an errorbar recipe
            errkw = copy(kw)
            errkw[:seriestype] = esym
            errkw[:label] = ""
            errkw[:primary] = false
            push!(kw_list, errkw)
        end
    end
end

function _add_smooth_kw(kw_list::Vector{KW}, kw::AKW)
    # handle smoothing by adding a new series
    if get(kw, :smooth, false)
        x, y = kw[:x], kw[:y]
        β, α = convert(Matrix{Float64}, [x ones(length(x))]) \ convert(Vector{Float64}, y)
        sx = [ignorenan_minimum(x), ignorenan_maximum(x)]
        sy = β .* sx .+ α
        push!(kw_list, merge(copy(kw), KW(
            :seriestype => :path,
            :x => sx,
            :y => sy,
            :fillrange => nothing,
            :label => "",
            :primary => false,
        )))
    end
end

# ------------------------------------------------------------------
# plot recipes

# Grab the first in line to be processed and pass it through apply_recipe
# to generate a list of RecipeData objects (data + attributes).
# If we applied a "plot recipe" without error, then add the returned datalist's KWs,
# otherwise we just add the original KW.
function _process_plotrecipe(plt::Plot, kw::AKW, kw_list::Vector{KW}, still_to_process::Vector{KW})
    if !isa(get(kw, :seriestype, nothing), Symbol)
        # seriestype was never set, or it's not a Symbol, so it can't be a plot recipe
        push!(kw_list, kw)
        return
    end
    try
        st = kw[:seriestype]
        st = kw[:seriestype] = get(_typeAliases, st, st)
        datalist = RecipesBase.apply_recipe(kw, Val{st}, plt)
        warn_on_recipe_aliases!(datalist, :plot, st)
        for data in datalist
            preprocessArgs!(data.plotattributes)
            if data.plotattributes[:seriestype] == st
                error("Plot recipe $st returned the same seriestype: $(data.plotattributes)")
            end
            push!(still_to_process, data.plotattributes)
        end
    catch err
        if isa(err, MethodError)
            push!(kw_list, kw)
        else
            rethrow()
        end
    end
    return
end


# ------------------------------------------------------------------
# setup plot and subplot

function _plot_setup(plt::Plot, plotattributes::AKW, kw_list::Vector{KW})
    # merge in anything meant for the Plot
    for kw in kw_list, (k,v) in kw
        haskey(_plot_defaults, k) && (plotattributes[k] = pop!(kw, k))
    end

    # TODO: init subplots here
    _update_plot_args(plt, plotattributes)
    if !plt.init
        plt.o = Base.invokelatest(_create_backend_figure, plt)

        # create the layout and subplots from the inputs
        plt.layout, plt.subplots, plt.spmap = build_layout(plt.attr)
        for (idx,sp) in enumerate(plt.subplots)
            sp.plt = plt
            sp.attr[:subplot_index] = idx
        end

        plt.init = true
    end


    # handle inset subplots
    insets = plt[:inset_subplots]
    if insets !== nothing
        if !(typeof(insets) <: AVec)
            insets = [insets]
        end
        for inset in insets
            parent, bb = is_2tuple(inset) ? inset : (nothing, inset)
            P = typeof(parent)
            if P <: Integer
                parent = plt.subplots[parent]
            elseif P == Symbol
                parent = plt.spmap[parent]
            else
                parent = plt.layout
            end
            sp = Subplot(backend(), parent=parent)
            sp.plt = plt
            push!(plt.subplots, sp)
            push!(plt.inset_subplots, sp)
            sp.attr[:relative_bbox] = bb
            sp.attr[:subplot_index] = length(plt.subplots)
        end
    end
    plt[:inset_subplots] = nothing
end

function _subplot_setup(plt::Plot, plotattributes::AKW, kw_list::Vector{KW})
    # we'll keep a map of subplot to an attribute override dict.
    # Subplot/Axis attributes set by a user/series recipe apply only to the
    # Subplot object which they belong to.
    # TODO: allow matrices to still apply to all subplots
    sp_attrs = Dict{Subplot,Any}()
    for kw in kw_list
        # get the Subplot object to which the series belongs.
        sps = get(kw, :subplot, :auto)
        sp = get_subplot(plt, _cycle(sps == :auto ? plt.subplots : plt.subplots[sps], series_idx(kw_list,kw)))
        kw[:subplot] = sp

        # extract subplot/axis attributes from kw and add to sp_attr
        attr = KW()
        for (k,v) in collect(kw)
            if is_subplot_attr(k) || is_axis_attr(k)
                attr[k] = pop!(kw, k)
            end
            if is_axis_attr_noletter(k)
                v = pop!(kw, k)
                for letter in (:x,:y,:z)
                    attr[Symbol(letter,k)] = v
                end
            end
            for k in (:scale,), letter in (:x,:y,:z)
                # Series recipes may need access to this information
                lk = Symbol(letter,k)
                if haskey(attr, lk)
                    kw[lk] = attr[lk]
                end
            end
        end
        sp_attrs[sp] = attr
    end

    # override subplot/axis args.  `sp_attrs` take precendence
    for (idx,sp) in enumerate(plt.subplots)
        attr = if !haskey(plotattributes, :subplot) || plotattributes[:subplot] == idx
            merge(plotattributes, get(sp_attrs, sp, KW()))
        else
            get(sp_attrs, sp, KW())
        end
        _update_subplot_args(plt, sp, attr, idx, false)
    end

    # do we need to link any axes together?
    link_axes!(plt.layout, plt[:link])
end

# getting ready to add the series... last update to subplot from anything
# that might have been added during series recipes
function _prepare_subplot(plt::Plot{T}, plotattributes::AKW) where T
    st::Symbol = plotattributes[:seriestype]
    sp::Subplot{T} = plotattributes[:subplot]
    sp_idx = get_subplot_index(plt, sp)
    _update_subplot_args(plt, sp, plotattributes, sp_idx, true)

    st = _override_seriestype_check(plotattributes, st)

    # change to a 3d projection for this subplot?
    if is3d(st)
        sp.attr[:projection] = "3d"
    end

    # initialize now that we know the first series type
    if !haskey(sp.attr, :init)
        _initialize_subplot(plt, sp)
        sp.attr[:init] = true
    end
    sp
end

# ------------------------------------------------------------------
# series types

function _override_seriestype_check(plotattributes::AKW, st::Symbol)
    # do we want to override the series type?
    if !is3d(st) && !(st in (:contour,:contour3d))
        z = plotattributes[:z]
        if !isa(z, Nothing) && (size(plotattributes[:x]) == size(plotattributes[:y]) == size(z))
            st = (st == :scatter ? :scatter3d : :path3d)
            plotattributes[:seriestype] = st
        end
    end
    st
end

function _prepare_annotations(sp::Subplot, plotattributes::AKW)
    # strip out series annotations (those which are based on series x/y coords)
    # and add them to the subplot attr
    sp_anns = annotations(sp[:annotations])
    # series_anns = annotations(pop!(plotattributes, :series_annotations, []))
    # if isa(series_anns, SeriesAnnotations)
    #     series_anns.x = plotattributes[:x]
    #     series_anns.y = plotattributes[:y]
    # elseif length(series_anns) > 0
    #     x, y = plotattributes[:x], plotattributes[:y]
    #     nx, ny, na = map(length, (x,y,series_anns))
    #     n = max(nx, ny, na)
    #     series_anns = [(x[mod1(i,nx)], y[mod1(i,ny)], text(series_anns[mod1(i,na)])) for i=1:n]
    # end
    # sp.attr[:annotations] = vcat(sp_anns, series_anns)
end

function _expand_subplot_extrema(sp::Subplot, plotattributes::AKW, st::Symbol)
    # adjust extrema and discrete info
    if st == :image
        xmin, xmax = ignorenan_extrema(plotattributes[:x]); ymin, ymax = ignorenan_extrema(plotattributes[:y])
        expand_extrema!(sp[:xaxis], (xmin, xmax))
        expand_extrema!(sp[:yaxis], (ymin, ymax))
    elseif !(st in (:pie, :histogram, :bins2d, :histogram2d))
        expand_extrema!(sp, plotattributes)
    end
    # expand for zerolines (axes through origin)
    if sp[:framestyle] in (:origin, :zerolines)
        expand_extrema!(sp[:xaxis], 0.0)
        expand_extrema!(sp[:yaxis], 0.0)
    end
end

function _add_the_series(plt, sp, plotattributes)
    warnOnUnsupported_args(plt.backend, plotattributes)
    warnOnUnsupported(plt.backend, plotattributes)
    series = Series(plotattributes)
    push!(plt.series_list, series)
    push!(sp.series_list, series)
    _series_added(plt, series)
end

# -------------------------------------------------------------------------------

# this method recursively applies series recipes when the seriestype is not supported
# natively by the backend
function _process_seriesrecipe(plt::Plot, plotattributes::AKW)
    #println("process $(typeof(plotattributes))")
    # replace seriestype aliases
    st = Symbol(plotattributes[:seriestype])
    st = plotattributes[:seriestype] = get(_typeAliases, st, st)

    # shapes shouldn't have fillrange set
    if plotattributes[:seriestype] == :shape
        plotattributes[:fillrange] = nothing
    end

    # if it's natively supported, finalize processing and pass along to the backend, otherwise recurse
    if is_seriestype_supported(st)
        sp = _prepare_subplot(plt, plotattributes)
        _prepare_annotations(sp, plotattributes)
        _expand_subplot_extrema(sp, plotattributes, st)
        _update_series_attributes!(plotattributes, plt, sp)
        _add_the_series(plt, sp, plotattributes)

    else
        # get a sub list of series for this seriestype
        x, y, z = plotattributes[:x], plotattributes[:y], plotattributes[:z]
        datalist = RecipesBase.apply_recipe(plotattributes, Val{st}, x, y, z)
        warn_on_recipe_aliases!(datalist, :series, st)

        # assuming there was no error, recursively apply the series recipes
        for data in datalist
            if isa(data, RecipeData)
                preprocessArgs!(data.plotattributes)
                if data.plotattributes[:seriestype] == st
                    error("The seriestype didn't change in series recipe $st.  This will cause a StackOverflow.")
                end
                _process_seriesrecipe(plt, data.plotattributes)
            else
                @warn("Unhandled recipe: $(data)")
                break
            end
        end
    end
    nothing
end
