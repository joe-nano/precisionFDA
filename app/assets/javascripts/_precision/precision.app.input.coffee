class AppInputModel
  constructor: (spec, @viewModel, isBatch = false) ->
    @batchInput = ko.observable(isBatch)
    @className = spec.class
    @help = spec.help
    @label = spec.label
    @name = spec.name
    @defaultValue = spec.default
    @defaultFileValue = ko.observable()
    @isOptional = spec.optional
    @isRequired = !@isOptional
    @patterns = spec.patterns
    @choices = spec.choices
    @buttonType = ko.computed(=>
      if @batchInput() == true
        'checkbox'
      else
        'radio'
    )
    @placeholder = @defaultValue

    @isClassAnArray = @className.indexOf('array') == 0

    @error = ko.observable(null)

    @licenseToAccept = ko.observable()
    @userLicense = ko.observable()

    @value = ko.observable(spec.default)
    @showClearButton = ko.computed(() =>
      @value() and !@defaultFileValue()
    )
    @showResetButton = ko.computed(() =>
      @value() and @defaultFileValue() and @value() != @defaultFileValue().uid
    )
    @valueDisplay = ko.computed({
      read: () =>
        appValue = @value()
        return appValue || @defaultValue if @className != 'file'
        return appValue.name if appValue and appValue.name
        return "Select file..." if !@defaultValue

        if @defaultFileValue()
          value = @defaultFileValue()
          if value.license? and !value.user_license?.accepted
            @licenseToAccept({
              license: value.license,
              user_license: value.user_license
            })
          return value.title

        if @defaultValue.match(new RegExp(/^file-(.{24,})$/, "i"))
          params = {
            uid: @defaultValue,
            describe: {
              include: {
                license: true
              }
            }
          }
          oldValue = @defaultValue
          @defaultValue = 'Loading...'
          Precision.api('/api/describe', params).done((value) =>
            @defaultFileValue(value)
            if value.license? && !value.user_license?.accepted
              @licenseToAccept({
                license: value.license,
                user_license: value.user_license
              })
          ).fail( =>
            @defaultValue = oldValue
            Precision.alert.showAboveAll('Something went wrong while getting file name')
          )
          return @defaultValue
        else
          console.error 'defaultValue', @defaultValue
          @error("Invalid default value: #{@defaultValue}")
          return @defaultValue


      write: (value) =>
        if !value?
          @value(null)
        else
          switch @className
            when 'boolean'
              if value == 'true'
                @value(true)
              else if value == 'false'
                @value(false)
              else
                @value(null)
            else
              @value(value)
    }
    )

    @isReady = ko.computed(=>
      @value()
      hasDefault = @defaultValue?
      isRequired = @isRequired
      hasData = false
      getDataForRun = @getDataForRun()
      if _.isArray(getDataForRun)
        hasData = getDataForRun.length > 0 && @validArray(getDataForRun) && getDataForRun != ''
      else if _.isBoolean(getDataForRun)
        hasData = true
      else
        hasData = getDataForRun && getDataForRun != ''
      hasError = @error() != null
      return !hasError && (!isRequired || (isRequired && (hasData || hasDefault)))
    )

    @needsToBeSet = ko.computed(=>
      return @isRequired && !@isReady()
    )

    @createSelectorModel()

  createSelectorModel: () =>
    return false if @className != 'file'
    @createSelectorModelOpts = ko.computed( =>
      return {
        title: "Select input for #{@label}",
        help: @help,
        selectionType: @buttonType(),
        selectableClasses: ["file"],
        onSave: (selected) =>
          @licenseToAccept(null)
          if !_.isArray(selected)
            @value({
              uid: selected.uid
              name: selected.title()
            })
            if selected.license()? && !selected.user_license.accepted()
              @licenseToAccept({
                license: selected.license(),
                user_license: selected.user_license()
              })
          else
            licensesToAccept = []
            # FIXME: This is untested
            @value(_.map(selected, (object) ->
              if object.license()? && !object.user_license.accepted()
                licensesToAccept.push({
                  license: object.license(),
                  user_license: object.user_license()
                })
              return {
                uid: object.uid
                name: object.title()
              }
            ))

            @licenseToAccept(licensesToAccept) if licensesToAccept?

          deferred = $.Deferred()
          deferred.resolve(@value())

        listRelatedParams: {
          scopes: @viewModel.contentScopes(),
          classes: [
            "file",
            "note",
            "discussion",
            "answer",
            "comparison",
            "app",
            "asset",
            "job",
            "workflow"
          ]
        },
        listModelConfigs: [
          {
            className: "file",
            name: "Files",
            apiEndpoint: "list_files",
            apiParams: {
              scopes: @viewModel.contentScopes()
              states: ["closed"]
              describe: {
                include: {
                  user: true,
                  org: true,
                  license: true,
                  all_tags_list: false
                }
              }
            },
            patterns: @patterns
          },
          {
            className: "note"
            name: "Notes"
            apiEndpoint: "list_notes"
            apiParams: {
              scopes: @viewModel.contentScopes(),
              note_types: ["Note"],
              describe: {
                include: {
                  user: true,
                  org: true,
                  all_tags_list: true
                }
              }
            }
          },
          {
            className: "discussion"
            name: "Discussions"
            apiEndpoint: "list_notes"
            apiParams: {
              scopes: @viewModel.contentScopes(),
              note_types: ["Discussion"],
              describe: {
                include: {
                  user: true,
                  org: true,
                  all_tags_list: true
                }
              }
            }
          }
        ]
      }
    )
    ### we need prop and observable here because it was defined in old implementation ###
    ### and i afraid both props used somethere else ###
    @objectSelector = new Precision.models.SelectorModel(@createSelectorModelOpts())
    @fileSelector = ko.observable(@objectSelector)

    @updateSelectorOpts = ko.computed( =>
      opts = @createSelectorModelOpts()
      @objectSelector.opts.onSave = opts.onSave
      @objectSelector.selectionType = opts.selectionType
      @objectSelector.listRelatedParams = opts.listRelatedParams
      @objectSelector.listModelConfigs = opts.listModelConfigs
      @fileSelector(@objectSelector)
    )

  validArray: (array) ->
    value = true
    _.map(array, (object) ->
      if !object?
        value = false
      )
    return value

  # Boolean Functions
  toggleTrue: (e) ->
    if @value() == true
      @value(null)
    else
      @value(true)
    $(".field-boolean .btn").blur()

  toggleFalse: (e) ->
    if @value() == false
      @value(null)
    else
      @value(false)
    $(".field-boolean .btn").blur()

  # File Functions
  openFileSelector: () ->
    @fileSelector().open()

  clear: () ->
    @valueDisplay(null)

  resetFileValue: () ->
    @valueDisplay(@defaultFileValue().uid)

  getDataForRun: () ->
    if @className == 'boolean'
      if @value()? && _.isArray(@value())? && @value().length > 0
        selectedData = @value()
      else if _.isBoolean(@value())
        selectedData = @value()
      else if @defaultValue?
        selectedData = @defaultValue

    if @defaultValue?
      selectedData = @defaultValue

    if @value()?
      selectedData = @value()

    if selectedData? && selectedData != ''
      try
        if @isClassAnArray && _.isString(selectedData)
          # Remove any trailing/leading commas
          selectedData = selectedData.replace(/(^\s*,)|(,\s*$)/g, '')
          selectedData = _.map(selectedData.split(','), (data) =>
            data = $.trim(data) # Remove trailing/leading whitespace
            _data = data
            switch @className
              when 'int'
                data = parseInt(data, 10)
                if _.isString(_data) && _data != data.toString()
                  @error("#{_data} is not a valid integer")
                else
                  @error(null)
              when 'float'
                data = parseFloat(data)
                if _.isString(_data) && _data != data.toString()
                  @error("#{_data} is not a valid integer")
                else
                  @error(null)
          )
        else if @className == "hash" && _.isString(selectedData)
          if selectedData.length > 0
            try
              value = JSON.parse(selectedData)
            catch error
              @error(error.message)
          else
            value = undefined
        else
          switch @className
            when 'int', 'string', 'float'
              value = @parseStringData(@className, selectedData)
            when 'file'
              if _.isString(selectedData)
                value = selectedData
              else if _.isArray(selectedData) && _.isObject(selectedData[0])
                value = selectedData[0].uid
              else if _.isObject(selectedData)
                value = selectedData.uid
              else
                value = selectedData
            when 'boolean'
              value = selectedData
            else
              value = selectedData
      catch error
        value = undefined
    else
      value = undefined
    return value

  parseStringData: (type, selectedData) =>
    return if !selectedData?
    switch type
      when 'int'
        parseDatum = (rawDatum) => parseInt(rawDatum, 10)
        dataType = 'integer'
      when 'string'
        parseDatum = (rawDatum) => rawDatum
        dataType = 'string'
      when 'float'
        parseDatum = (rawDatum) => parseFloat(rawDatum, 10)
        dataType = 'float'
      else
        return

    if @batchInput() == true
      [values, errors, missingInput, data_arr]  = [[], [], false, selectedData.split(',')]
      for rawDatum in data_arr
        parsedDatum = parseDatum(rawDatum)
        if rawDatum == "" && @isRequired
          missingInput = true
        else if _.isString(rawDatum) && rawDatum != parsedDatum.toString()
          errors.push("#{rawDatum} is not a valid #{dataType}")
        else
          values.push(parsedDatum)
      errors.push("All batch inputs must be defined for this input") if missingInput

      if errors.length > 0
        @error(errors.join(". "))
        return null
      else
        @error(null)
        return values
    else
      parsedDatum = parseDatum(selectedData)
      if _.isString(selectedData) && selectedData != parsedDatum.toString()
        @error("#{selectedData} is not a valid #{dataType}")
        return null
      else
        @error(null)
        return parsedDatum

  getDataForBatchRun: () =>
    if @value()
      value = @value()
    else if @defaultValue
      value = @defaultValue

    try
      switch @className
        when 'int'
          if _.isNumber(value)
            value = parseInt(value, 10)
          else
            value = _.map(value.split(','), (data) =>
              data = $.trim(data)
              parseInt(data, 10)
            )
        when 'string'
          value = _.map(value.split(','), (data) =>
            data = $.trim(data)
            data.toString()
          )
        when 'float'
          value = _.map(value, (data) =>
            data = $.trim(data)
            parseFloat(data, 10)
          )
        when 'file'
          if _.isArray(value)
            value = _.map(value, (data) =>
              data.uid
            )
          else
            value
    catch error
      value = undefined

    return value

window.Precision ||= {}
window.Precision.models ||= {}
window.Precision.models.AppInputModel = AppInputModel
