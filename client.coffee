#!/usr/bin/env coffee
###
#   Remote MakeMKV client logic
#         
#   Display MakeMKV stats to user, send commands to server
#    
#   @author     David Lasley, dave@dlasley.net
#   @website    https://dlasley.net/blog/projects/remote-makemkv/
#   @package    remote-makemkv
#   @license    GPLv3
###

class MakeMKVClient
    
    # Socket.io already has this built in to a point, just not for long periods
    RECONNECT_MS = 1000000
    
    #   Construct the socket, set callbacks
    #   @param  bool    bind    Bind the buttons? Default, yes
    constructor: (bind=true) -> 
        
        dc_err = () =>
            @_error('Server Unavailable', 'The server is unavailable. Attempting to reconnect.')
        
        #   (re)connect to socket, clear interval
        init_socket = () =>

            if not @socket
                @socket = io.connect(window.location.host)
                
                if @socket and @socket.connected
                    $(document.getElementById('modal')).modal('hide')
                else
                    dc_err()
                    @socket_timeout = setTimeout(init_socket, @RECONNECT_MS)
            else
                @socket.connect()
                if @socket.connected
                    $(document.getElementById('modal')).modal('hide')
                else
                    dc_err()
                    @socket_timeout = setTimeout(init_socket, @RECONNECT_MS)
        
        init_socket()

        @socket.on('connect', () =>
            console.log('Connected to server')
        )

        #   Bind to receive/process socket cmds
        @socket.on('change_out_dir', (data) => @change_out_dir(data))
        @socket.on('scan_drives', (data) => @scan_drives(data))
        @socket.on('udev_update', (data) =>
            @scanned_drive(data.data.disc_id, data.data.label)
        )
        @socket.on('disc_info', (data) => @disc_info(data))
        @socket.on('rip_track', (data) => @rip_track(data))
        @socket.on('list_dir', (data) => @list_dir(data))
        @socket.on('_panel_disable', (data) => @panel_disable_socket(data))
        @socket.on('_error', (data) => @_error(data.data.type, data.data.msg))

        @socket.on('disconnect', () =>
            dc_err()
            document.getElementById('main').innerHTML = ''
            @socket_timeout = setTimeout(init_socket, @RECONNECT_MS)
            console.log('Server D/C')
        )

        #   Socket debugging
        @socket.on('message', (data) =>
            console.log('Client sent: ', data)
        )

        if bind
            @_bind()

    #   Bind client events
    _bind: () =>
        
        #   Send new outdir to server
        $(document.getElementById('send_out_dir')).on('click', (event) =>
            new_dir = $('#output_dir').val()
            @_socket_cmd('change_out_dir', new_dir)
        )
        
        #   Refresh all button
        $(document.getElementById('refresh_all')).on('click', (event) =>
            @_panel_disable()
            @_socket_cmd('scan_drives', true)
        )
        
        #   Browse button
        $(document.getElementById('browse_fs')).on('click', (event) =>
            @list_dir()
        )
        
        #   Disc panel buttons (getinfo, rip)
        $(document.getElementById('main')).on('click', '.get-info', (event) =>
            drive_id = event.currentTarget.getAttribute('data-drive-id')
            @_panel_disable($(document.getElementById(drive_id)))
            @_socket_cmd('disc_info', drive_id)
        )
        
        #   Track Rip Buttons (in each panel)
        .on('click', '.rip-tracks', (event) =>
            
            drive_id = event.currentTarget.getAttribute('data-drive-id')
            panel = $(document.getElementById(drive_id))
            save_dir = document.getElementById(drive_id + '_name').value

            @_panel_disable(panel, true)
            
            checked_boxes = []
            for check in panel.find('input[type="checkbox"]')
                if check.checked
                    checked_boxes.push(check.getAttribute('data-track-id'))
                
            @_socket_cmd('rip_track', {
                'save_dir':save_dir, 'drive_id':drive_id,
                'track_ids':checked_boxes
            })
        )
        
        #   Select all checks (in disc panel)
        .on('change', '.rip-toggle', (event) ->
            check = $(event.currentTarget)
            check.parents('table').find('.rip-chk').prop(
                'checked', !check.prop('checked')
            )
        )
        
        #   Panel collapse/expand
        .on('click', '.panel-toggle', (event) =>
            panel = document.getElementById(event.currentTarget.getAttribute('data-drive-id')) #< id=disc_title
            @_panel_collapse(panel)
        )
        
        #   Track row click to check
        .on('click', '.track-row td', (event) =>
            
            child = event.currentTarget.childNodes[0]
            if child
                if child.type == 'checkbox'
                    return
            
            checks = $(event.currentTarget.parentElement).find('input:checkbox')
            checks.prop('checked', !checks.prop('checked'))
        
        )
        
        $(document.getElementById('modal_select')).on('click', (event) =>
            $(document.getElementById('modal')).modal('hide')
            selected = $(document.getElementById('dir_select')).find(":selected")
            ids = (el.getAttribute('value') for el in selected)
            @socket.emit('scan_dirs', ids)
        )

    #   Display error modal
    #   @param  str type Error type, modal title
    #   @param  str msg  Error message, modal body 
    _error: (type, msg) ->
        
        document.getElementById('modal_title').innerHTML = type
        $(document.getElementById('modal_error')).html(msg).removeClass('hidden')
        $(document.getElementById('modal_select')).addClass('hidden')
        $(document.getElementById('dir_tree')).addClass('hidden')
        $(document.getElementById('modal')).modal('show')
    
    #   Send JSON.stringify(data)
    #   @param  str     cmd     Command that is being performed
    #   @param  mixed   data    Data to send
    _socket_cmd: (cmd, data) =>
        
        @socket.emit(cmd, data)
    
    #   Create a new el
    #   @param  obj parent  perform parent.appendChild(this)
    #   @param  str class_  Class of el
    #   @param  str type_   Type of element to create
    #   @param  obj kwargs  Dict of attrs to set
    #   @return obj 
    _new_el: (parent=false, class_=false, type_='div', kwargs={}) ->
        
        $el = $('<' + type_ + '>')
        
        if class_
            $el.addClass(class_)
            
        if parent
            #   Handle both jQuery and non
            if parent.appendChild
                $(parent).append($el)
            else
                parent.append($el)
        
        for attr of kwargs
            switch(attr)
                when 'html' then $el.html(kwargs[attr])
                else $el.attr(attr, kwargs[attr])
        
        $el
    
    #   Create a new disc panel on UI
    #   @param  str drive       Drive ID, or dir
    #   @param  str disc_name   Disc ID
    #   @param  int width       Grid width of panel container
    #   @return DivElement
    new_disc_panel: (drive, disc_name='None', width=6) =>
        
        container = @_new_el(false, 'col-lg-' + width)
        panel = @_new_el(container, 'panel panel-info disc_', 'div', {id:drive})
        
        heading = @_new_el(panel, 'panel-heading')
        header_container = @_new_el(heading)
        
        title = @_new_el(header_container, 'panel-title', 'div', {id:drive + '_title'})
        
        t_grid = @_new_el(title, 'row')
        
        #   Get Disc Info Button
        _div = @_new_el(t_grid, 'col-sm-1', 'div')
        refresh_btn = @_new_el(_div, 'btn btn-default disc-info-btn get-info',
                               'button', {'data-drive-id':drive, 'type':'button', }
        )
        @_new_el(refresh_btn, 'glyphicon glyphicon-refresh get-info', 'span',
                {'data-drive-id':drive, 'type':'button',})
        
        @_new_el(t_grid, 'col-sm-10 title-text', 'div', {html:disc_name})
        
        _div = @_new_el(t_grid, 'col-sm-1', 'div')
        refresh_btn = @_new_el(_div, 'btn btn-default disc-info-btn panel-toggle',
                               'button', {'data-drive-id':drive, 'type':'button', }
        )
        @_new_el(refresh_btn, 'glyphicon glyphicon-minus', 'span')

        body = @_new_el(panel, 'panel-body', 'div', {id:drive + '_body'})
        footer = @_new_el(panel, 'panel-footer', 'div')
        
        footer_div = @_new_el(footer, 'row')
        
        #   Get Disc Info Button
        refresh_btn = @_new_el(
            @_new_el(footer_div, 'col-md-2'),
            'btn btn-default disc-info-btn get-info', 'button',
            {'data-drive-id':drive, 'type':'button', html:'Refresh Disc',}
        )

        #   Rip Tracks Button
        @_new_el(
            @_new_el(footer_div, 'col-md-2 col-md-offset-7'),
            'btn btn-default disc-info-btn hidden rip-tracks', 'button',
            {'data-drive-id':drive, 'type':'button', html:'Rip Track(s)',}
        )
        
        container
    
    #   Callback for scan_drives cmd
    #       Displays all drive data
    #   @param  dict    socket_in  Data dict passed from server
    scan_drives: (socket_in) =>
        
        data = socket_in['data']

        for drive, disc of data
            @scanned_drive(drive, disc)
        
        @_panel_disable(false, false)
    
    ##  Single scanned drive callback
    #   @param  str drive   drive id
    #   @param  str disc    disc name
    scanned_drive: (drive, disc) =>
        
        #   Kill old panel
        if panel = document.getElementById(drive)
            @_panel_shift(panel, false)
        
        panel = @new_disc_panel(drive, drive + ' -- ' + disc)
        @_panel_shift(panel)
    
    ##  Add or remove a disc panel
    #   @param  obj     panel   Disc panel
    #   @param  bool    add     Add panel, false to remove
    _panel_shift: (panel, add=true) ->
        
        if add

            for row in $('#main>.row')
                if row.children.length == 1
                    $(row).append(panel)
                    added = true
            
            if not added
                
                console.log(panel)
                @_new_el($('#main'), 'row').append(panel)
                
        else
            
            panel.parent.removeChild(panel)
            #   @todo - actually shift the panels
            
    #   Callback for disc_info cmd
    #       Displays disc info in disc panel
    #   @param  dict    socket_in  Data dict passed from server
    disc_info: (socket_in) =>
        
        data = socket_in.data
        console.log(data)

        #   Get Disc panel body and clear it
        if data.disc_id.indexOf('/dev') > -1
            
            disc_panel = document.getElementById(data.disc_id + '_body')
            
            if not disc_panel
                @_panel_shift(@new_disc_panel(data.disc_id, title))
                disc_panel = document.getElementById(data.disc_id + '_body')
            
            document.getElementById(data.disc_id).className = 'panel panel-primary disc_'
            disc_panel = $(disc_panel)
            disc_panel.html('')
            @_panel_disable(disc_panel, false)
            title = data.disc_id + ' -- ' + data.disc.name
            $(document.getElementById(data.disc_id + '_title')).find('.title-text').html(title)
        
        #   Fallback for directory rip panel
        else    
            
            is_dir = true
            title = data.dir + ' -- ' + data.disc.name
            data.disc_id = data.dir
            disc_panel = document.getElementById(data.dir + '_body')
            
            if not disc_panel
                @_panel_shift(@new_disc_panel(data.dir, title))
                disc_panel = document.getElementById(data.dir + '_body')

            disc_panel = $(disc_panel)
            disc_panel.html('')
            document.getElementById(data.dir).className = 'panel panel-primary disc_'
        
        if data.disc.name #< Only display the form/table if there's actually a disc
            
            #   Form and form container
            form = @_new_el(disc_panel, 'form-horizontal', 'form', {role:'form'})
            form_div = @_new_el(form, 'form-group')
            
            #   Label for input
            label = @_new_el(form_div, 'col-sm-2 control-label', 'label', { 
                'for':data['disc_id'] + '_name', html: 'Disc Name'
            })
            
            #   Input container and input
            input_div = @_new_el(form_div, 'col-sm-10')
            input_el = @_new_el(input_div, 'form-control', 'input', {
                placeholder:data['disc']['Sanitized'], value:data['disc']['Sanitized'],
                id:data['disc_id'] + '_name'
            })
            
            #   Table for all the tracks (and the responsive container for it)
            tbl_cont = @_new_el(disc_panel, 'table-responsive')
            table = @_new_el(tbl_cont, 'table table-bordered table-condensed table-hover', 'table')
            
            #   Disc info header map and loop
            headers = {
                '#':false, 'Source':'Source File Name', 'Chptrs':'Chapter Count',
                'Size':'Disk Size', 'Track Types':'_ttypes', 'S-Map':'Segments Map',
            }
            
            row = @_new_el(@_new_el(table, false, 'thead'), false, 'tr')
            row.css('cursor', 'pointer')
            
            ripall = @_new_el(@_new_el(row, false, 'th'), 'rip-toggle', 'input',
                              {type:'checkbox'})
            
            for header of headers
                col = @_new_el(row, false, 'th', {html:header})
                if header == 'Size'
                    col.attr('data-metric-name', 'b|byte')
                    col.addClass('sorter-metric')
    
            tbody = @_new_el(table, false, 'tbody')
            
            #   Loop tracks, display data
            for track_id, track_data of data['tracks']
                
                #   Initial row, track #, checkboxes
                row = @_new_el(tbody, 'track-row', 'tr')
                
                col = @_new_el(row, false, 'td')
                @_new_el(col, 'rip-chk', 'input', {
                    type:'checkbox', 'data-track-id':track_id,
                    'data-autochecked':track_data['_autochk'],
                    checked:track_data['_autochk']
                })
                
                col = @_new_el(row, false, 'td', {html:track_id})
                
                #   Fill Track Type Cnts
                track_cnts = track_data['cnts']
                cnt_key_order = ['Video', 'Audio', 'Subtitles']
                track_data['_ttypes'] = []
                for key in cnt_key_order
                    track_data['_ttypes'].push('<em>' + key + ':</em>' + track_cnts[key])
                track_data['_ttypes'] = track_data['_ttypes'].join(', ')
                
                #   Loop the rest of the cols
                for _, header of headers
                    if header
                        col_data = track_data[header]
                        @_new_el(row, false, 'td', {html:col_data})

            table.tablesorter()
                        
            panel = $(document.getElementById(data['disc_id']))
    
            if is_dir
                panel.find('.get-info').addClass('hidden')
            else
                @_panel_disable(panel, false)
            
            #   Un-hide Rip Button
            panel.find('.rip-tracks').removeClass('hidden')
        
    #   Receive track rip status, output to GUI
    #   @param  dict    socket_in    Data dict passed from server
    rip_track: (socket_in) =>
        
        console.log(socket_in)
        
        data = socket_in['data']
        panel_ = document.getElementById(data['disc_id'])
        panel = $(panel_)
        
        @_panel_disable(panel, false)

        results = []
        for track_id, result of data['results']
            
            if result
                result = 'bg-success'
                results.push(true)
            else
                result = 'bg-danger'
                results.push(false)
                
            chk_box = panel.find('input[data-track-id="' + track_id + '"]')
            $(chk_box).parent().parent().removeClass().addClass(result)
            
        if false in results
            if true in results
                panel_.className = 'panel panel-warning disc_'
            else
                panel_.className = 'panel panel-danger disc_'
        else
            panel_.className = 'panel panel-success disc_'
            
        #   Notify browser tab when done
        is_old = true
        title_obj = $('title')
        title_old = title_obj.text()
        title_new = 'Rip Complete! ' + title_old
        interval = null
        
        changeTitle = () ->
            document.title = is_old ? title_old : title_new
            is_old = !is_old
            
        $(window).focus( () ->
            clearInterval(interval)
            title_obj.text(title_old)
        )
        
    #   List directory in a modal
    #   @param  list    dir Directory listing
    list_dir: (dir='/') =>
        
        $(document.getElementById('modal_error')).addClass('hidden')
        $(document.getElementById('modal_select')).removeClass('hidden')
        $(document.getElementById('modal')).modal('show')
        
        dir_tree = $(document.getElementById('dir_tree'))
        dir_tree.removeClass('hidden').html('Loading...')
        
        document.getElementById('modal_title').innerHTML = 'Listing ' + dir
        
        $.get('/list_dir', {'dir':'/'}, (data) =>
            
            select = @_new_el(false, 'form-control', 'select', {id:'dir_select'})
            select.attr('multiple', true).height('500')
            
            for item in data
                option = @_new_el(select, false, 'option', {value:item.id, html:item.text})
            
            $(document.getElementById('dir_tree')).html('').append(select)
        , 'JSON')
            
    #   Receive output dir and change on display
    #   @param  dict    socket_in    Data dict passed from server
    change_out_dir: (socket_in) ->    
        
        document.getElementById('output_dir').value = socket_in['data']
    
    ##  UI function to (un)collapse panel
    #   @param  obj panel   Bootstrap3 Panel obj
    _panel_collapse: (panel) ->
        
        panel = $(panel)
        collapse = $(panel.children('.panel-body, .panel-footer'))
        glyph =  $(panel.find('.glyphicon')[0])
        
        collapse.toggleClass('hidden')
        glyph.toggleClass('glyphicon-minus')
        glyph.toggleClass('glyphicon-plus')
        
        #   Clear most likely unintentional selection
        if window.getSelection
            if window.getSelection().empty #< Chrome
                window.getSelection().empty()
            else if window.getSelection().removeAllRanges #< FF
                window.getSelection().removeAllRanges()
        else if document.selection #< IE
            document.selection.empty()
            
    ##  Disable panel with socket received data
    #   @param  dict    socket_in   Data dict passed from server
    panel_disable_socket: (socket_in) =>
        
        if socket_in.disc_id == 'all'
            panel = false
        else
            panel = $(document.getElementById(socket_in.disc_id))
        
        if socket_in.busy == undefined
            @_panel_disable(panel, false)
        else
            @_panel_disable(panel, socket_in.busy)
            
    ##  Disable a panel's input els
    #   @param  $(obj)  panel   Panel jQuery obj, false to select all panels
    #   @param  bool    disable False to enable panel
    _panel_disable: (panel=false, disable=true) ->
        
        if not panel
            panel = $('.disc_')
            $('.disc-btn').prop('disabled', disable)
            
        panel.find(':input').prop('disabled', disable)
        
        if disable
            panel.removeClass().addClass('panel panel-default disc_')
            
client = new MakeMKVClient()
