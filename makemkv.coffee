#!/usr/bin/env coffee
###
#   Makemkvcon object
#         
#   Manipulate makemkv with node.js
#    
#   @author     David Lasley, dave@dlasley.net
#   @website    https://dlasley.net/blog/projects/remote-makemkv/
#   @package    remote-makemkv
#   @license    GPLv3
###

fs = require('fs')
path = require('path')
{EventEmitter} = require('events')
spawn = require('child_process').spawn
SanitizeTitles = require(__dirname + '/sanitize_titles.coffee')

class MakeMKV

    constructor: (save_to) ->
        
        @emitter = new EventEmitter
        
        @NEWLINE_CHAR = '\n'
        @COL_PATTERN = /((?:[^,"\']|"[^"]*"|\'[^']*\')+)/
        @busy_devices = {}
        
        SETTINGS_PATH = path.join(__dirname, '/settings.json')
        SETTINGS_DATA = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf-8'))
        
        @ATTRIBUTE_IDS = SETTINGS_DATA.attribute_ids

        @USER_SETTINGS = SETTINGS_DATA.USER_SETTINGS
        
        @CONVERSION_PROFILE = path.join(__dirname, @USER_SETTINGS.conversion_profile)
        @MAKEMKVCON_PATH = @USER_SETTINGS.makemkvcon_path
        @LISTEN_PORT = @USER_SETTINGS.listen_port
        @OUTLIER_MODIFIER = @USER_SETTINGS.outlier_modifier

        @sanitizer = new SanitizeTitles()
        
        # Chars not allowed on the filesystem
        @RESERVED_CHAR_MAP = SanitizeTitles.RESERVED_CHAR_MAP
        @PERMISSIONS = {'file':'0666', 'dir':'0777'} #< New file and dir permissions @todo

        @save_to = if save_to then save_to else @USER_SETTINGS.output_dir
        
    ##  Choose the tracks that should be autoselected
    #   @param  dict    disc_info   As returned in @disc_info()
    #   @return dict    disc_info with injected `autoselect` key in every track (bool)
    choose_tracks: (disc_info, callback=false) =>
        
        track_sizes = []
        for track_id, track_data of disc_info.tracks
            track_sizes.push([track_id, track_data['Disk Size Bytes']]) #< for sorting
        
        #   Calc upper quartile
        track_sizes.sort((a, b) -> a[1] - b[1])
        uq = Math.round(track_sizes.length * 0.75 * (@OUTLIER_MODIFIER / 100))
        
        for track, key in track_sizes
            disc_info['tracks'][track[0]]['_autochk'] = key >= uq
 
        if callback
            callback(disc_info)
        else
            disc_info
        
    ##  Determine which discs are being used
    #   @param  int  disc_id Disc ID
    #   @param  bool busy
    #   @return bool Is the drive (or any if no disc_id) busy
    toggle_busy: (disc_id, busy) =>
        
        if not disc_id
            @busy_devices['all'] = busy
            {
                'cmd'   :   'toggle_busy',
                'val'   :   @busy_devices
            }
        else
            if @busy_devices[disc_id]
                if busy == @busy_devices[disc_id] #< Busy disc
                    false
                
            @busy_devices[disc_id] = busy #< gtg
            true
            
    ##  Rip a track to save_dir (dir)
    #   @param  str     save_dir    Folder to save files in
    #   @param  int     disc_id     Drive ID
    #   @param  list    track_ids   List of ints (track IDs) to rip
    #   @param  func    callback    Callback function, will receive return var as param
    #   @return dict    Rip success? Keyed by track ID
    rip_track: (save_dir, disc_id, track_ids, callback=false) =>
        
        ripped_tracks = {'data':{'disc_id':disc_id, 'results':{}}, 'cmd':'rip_track'}
        save_dir = path.join(@save_to, save_dir)
        
        #   Critical failure, report for all tracks
        return_false = () =>
            for track_id in track_ids
                ripped_tracks['data']['results'][track_id] = false
            @toggle_busy(disc_id, false) 
            ripped_tracks
        
        #   Loop tracks to rip one at a time.
        #   @todo - status monitoring signals
        __recurse_tracks = (track_ids, ripped_tracks) =>
            
            track_id = track_ids.pop()
            
            if track_id == undefined #< Tracks done
                
                track_regex = /t(itle|rack)?(\d{1,2}).mkv/gi
                @toggle_busy(disc_id, false)
                
                #   Loop tracks, normalize the names
                fs.readdir(save_dir, (err, files) =>
                    split_dir = save_dir.split(path.sep)
                    basename = split_dir[split_dir.length - 1]
                    for file in files
                        if file.indexOf('.mkv', file.length-4) != -1
                            try
                                if track_num = track_regex.exec(file)[2]
                                    new_name = basename + ' t' + track_num + '.mkv'
                                    new_path = path.join(save_dir, new_name)
                                    console.log('Renaming "' + file + '" to "' + new_name + '"')
                                    fs.rename(path.join(save_dir, file), new_path)
                            catch err
                                console.error("Rename fail: \r\n" + track_regex.exec(file) +
                                              "\r\n" + err)
                    
                    if callback
                        callback(ripped_tracks)
                    else
                        ripped_tracks #< Return
                            
                )
                
            else
                
                if disc_id.indexOf('/dev/') == 0
                    cmd = 'dev:'
                else
                    extension = disc_id.split('.')
                    cmd = if extension[extension.length - 1] in ['img', 'iso'] then 'iso:' else 'file:'

                @_spawn_generic(['-r', '--noscan', 'mkv', '--cache=256', '--profile=' + @CONVERSION_PROFILE
                                cmd+disc_id, track_id, save_dir, ], (code, data) =>
                    
                    if code == 0
                        
                        #   Determine ripping success
                        for row in data
                            if row.indexOf('1 titles saved.') != -1
                                ripped_tracks['data']['results'][track_id] = true
                                break
                            
                        if not ripped_tracks['data']['results'][track_id]
                            
                            error = 'disc_info failed on ' + disc_id + ':' + track_id + '. Output was:\r\n' + data
                            console.log(error)
                            ripped_tracks['data']['results'][track_id] = false
                        
                    else
                

                        error = 'disc_info failed on ' + disc_id + ':' + track_id + '. Output was:\r\n' + data
                        console.log(error)
                        ripped_tracks['data']['results'][track_id] = false
                        
                    #   Next up
                    __recurse_tracks(track_ids, ripped_tracks)
                
                )
            
        #   If disc not busy, set busy and go
        if @toggle_busy(disc_id, true) 
            
            save_dir = @_mk_dir(save_dir)
            if not save_dir
                if callback
                    callback(return_false())
                else
                    return return_false()

            __recurse_tracks(track_ids, ripped_tracks, __recurse_tracks)
        
        else
            false
            
    

    ##  Scan drives, return info. Also sets @drive_map
    #   @param  func    callback Callback function, will receive drives as param
    #   @return dict    drives  Dict keyed by drive index, value is movie name
    scan_drives: (callback=false) =>
        
        if @toggle_busy(false, true) #< Make sure none of the discs are busy
            drives = {'cmd':'scan_drives', 'data':{}}
            @drive_map = {}
            #   Spawn MakeMKV with callback
            @_spawn_generic(['-r', 'info'], (code, drive_scan)=>
                try
                    for line in drive_scan
                        #   DRV to make sure it's drive output, /dev to make sure that there is a drive
                        if line[0..3] == 'DRV:' and line.indexOf('/dev/') != -1 
                            info = line.split(@COL_PATTERN)
                            #   Assign drive_location, strip quotes
                            drive_location = info[info.length - 2][1..-2]
                            #   [Drive Index] = Movie Name
                            if info[info.length - 4] != '""'
                                #   Assign drive info, strip quotes
                                drives['data'][drive_location] =  info[info.length - 4][1..-2]
                            else
                                drives['data'][drive_location] = false 
                            @drive_map[drive_location] = info[1].split(':')[1] #<    Index the drive location to makemkv's drive ID
                catch err
                    console.log('disc_scan: ' + err)
                    
                @toggle_busy(false)

                if callback
                    callback(drives)
                else
                    drives
            )


    ##  Get disc info
    #   @param  int     disc_id     Disc ID
    #   @param  func    callback    Callback function, will receive info_out as param
    #   @return dict    info_out    Disc/track information
    disc_info: (disc_id, callback=false) =>
        
        if disc_id
            if @toggle_busy(disc_id, true) #< If disc not busy, set busy and go
                
                info_out = {
                    'data':{
                        'disc':{}, 'tracks':{}, 'disc_id':disc_id
                    },
                    'cmd':'disc_info'
                }
                return_ = []
                errors = []
                
                @_spawn_generic(['--noscan', '-r', 'info', 'dev:'+disc_id, ], (code, disc_info)=>
                    
                    if code == 0
                        
                        if disc_info.indexOf('Failed to open disc') != -1
                            error = 'disc_info failed on ' + disc_id +'. Output was:\r\n'+ disc_info
                            console.log(error)
                            @_error('disc_info failed to open disc', error)
                        else
                            @parse_disc_info(disc_info, info_out, callback)
    
                        @toggle_busy(disc_id)
                        
                    else
                        error = 'disc_info failed on ' + disc_id +'. Output was:\r\n'+ disc_info
                        console.log(error)
                        @_error('disc_info returned bad exit code', error)
                )
                
            else
                false
            
    ##  Get disc info from folder
    #   @param  str     dir         Dir to scan
    #   @param  func    callback    Callback function, will receive info_out as param
    #   @return dict    info_out    Disc/track information (into callback)
    scan_dir: (dir, callback) =>
        
        info_out = {
            'data':{'disc':{}, 'tracks':{}, 'dir':dir}, 'cmd':'disc_info'
        }
        return_ = []
        errors = []
            
        extension = dir.split('.')
        
        cmd = if extension[extension.length - 1] in ['img', 'iso'] then 'iso:' else 'file:' 
        
        @_spawn_generic(['--noscan', '-r', 'info', cmd+dir, ], (code, disc_info)=>
            
            if code == 0
                
                if disc_info.indexOf('Failed to open disc') != -1
                    error = 'scan_dir failed on ' + disc_id +'. Output was:\r\n'+ disc_info
                    console.log(error)
                    @_error('scan_dir failed to open disc', error)
                else
                    @parse_disc_info(disc_info, info_out, callback)
                
            else
                
                error = 'scan_dir failed on ' + disc_id +'. Output was:\r\n'+ disc_info
                console.log(error)
                @_error('scan_dir returned bad exit code', error)
        )
            
    ##  Parse disc info as returned from MakeMKV
    #   @param  list    disc_info   Console output from `makemkvcon info`, split by line
    #   @param  dict    info_out    info_out var initialized in scan_dir or scan_disc
    #   @param  func    callback    Callback function, will receive info_out as param
    #   @return dict    info_out    Disc/track information
    parse_disc_info: (disc_info, info_out, callback=false) =>
        
        for line in disc_info
                        
            #   Loop the line split by COL_PATTERN, take every 2 starting at index 1
            split_line = []
            for col in line.split(@COL_PATTERN)[1..] by 2
                split_line.push(col)

            #   @todo - fix this atrocious code
            if split_line.length > 1 and split_line[0] != 'TCOUNT'

                switch(line[0])
                    
                    when 'M' #< MSG
                        msg_id = split_line[0].split(':').pop()
                        
                        #switch(msg_id)
                        #    
                        #    when '3307' #< Track added, capture original name
                        #        #   2112.m2ts has been ... as #123
                        #        matches = split_line[3].match(/(\d+\.[\w\d]+) .*? #(\d)/)
                        #        title_map[matches[2]] = matches[1]
                    
                    when 'C' #< CINFO (Disc Info)
                        attr_id = split_line[0].split(':').pop()
                        attr_val = split_line.pop()[1..-2]
                        info_out['data']['disc'][ \
                            if attr_id of @ATTRIBUTE_IDS then @ATTRIBUTE_IDS[attr_id] else attr_id 
                        ] = attr_val
                    
                    when 'T' #< Track
                        track_id = split_line[0].split(':').pop()
                        if track_id not of info_out['data']['tracks']
                            track_info = info_out['data']['tracks'][track_id] = {
                                'cnts':{'Subtitles':0, 'Video':0, 'Audio':0, }
                            }
                        attr_id = split_line[1]
                        track_info[ \
                            if attr_id of @ATTRIBUTE_IDS then @ATTRIBUTE_IDS[attr_id] else attr_id 
                        ] = split_line.pop()[1..-2]
                    
                    when 'S' #< Track parts
                        track_id = split_line[0].split(':').pop()
                        track_part_id = split_line[1]
                        if 'track_parts' not of info_out['data']['tracks'][track_id]
                            info_out['data']['tracks'][track_id]['track_parts'] = {}
                        if track_part_id not of info_out['data']['tracks'][track_id]['track_parts']
                            info_out['data']['tracks'][track_id]['track_parts'][track_part_id] = {}
                        track_info = info_out['data']['tracks'][track_id]['track_parts'][track_part_id]
                        attr_id = split_line[2]
                        track_info[ \
                            if attr_id of @ATTRIBUTE_IDS then @ATTRIBUTE_IDS[attr_id] else attr_id 
                        ] = split_line.pop()[1..-2]
                            
        #   Count the track parts (Audio/Video/Subtitle)
        for track_id of info_out['data']['tracks']
            
            smap = info_out['data']['tracks'][track_id]['Segments Map'].replace(/,/g, ' ')
            info_out['data']['tracks'][track_id]['Segments Map'] = smap
            has_tracks = true
            
            for part_id of info_out['data']['tracks'][track_id]['track_parts']
                track_part = info_out['data']['tracks'][track_id]['track_parts'][part_id]
                info_out['data']['tracks'][track_id]['cnts'][track_part['Type']]++
        
        if has_tracks
            
            #   Sanitize Title Names
            title = info_out['data']['disc']['Name']
            fallbacks = []
            fallbacks_ = ['Tree Info', 'Volume Name']
            
            for type_ in fallbacks_
                if info_out['data']['disc'][type_]
                    fallbacks.push(info_out['data']['disc'][type_])
                    
            info_out['data']['disc']['Sanitized'] = @sanitizer.do_sanitize(title, fallbacks)
            
            info_out['data'] = @choose_tracks(info_out['data']) #<  Autoselect titles
    
            if callback
                callback(info_out)
            else
                info_out #< Return
                
        else
            
            error = 'disc_info failed, no tracks found.'
            console.log(error)
            
            if callback
                callback(info_out)
            else
                info_out

    ##  Generic Application Spawn
    #   @param  list    args    List of str arguments
    #   @param  funct   callback
    #   @param  str     path    to binary
    #   @callback(list    List of lines returned from err and out @todo - split these)
    _spawn_generic: (args, callback=false, path=@MAKEMKVCON_PATH) =>
        
        console.log('Spawning ' + path + ' with args ' + args)
        
        #   Spawn process, init return var
        makemkv = spawn(path, args)
        return_ = []
        
        #   Set slots, push into & return on exit
        makemkv.stdout.setEncoding('utf-8')
        makemkv.stdout.on('data', (data)=>
            return_.push(data)
        )
        
        makemkv.stderr.setEncoding('utf-8')
        makemkv.stderr.on('data', (data)=>
            return_.push(data)
        )
        
        makemkv.on('exit', (code)=>
            return_ = return_.join('')
            
            if return_.indexOf('This application version is too old') != -1
                error = 'MakeMKV Evaluation Period Has Expired. Please obtain a license key or update your software at <a href="http://www.makemkv.com/">http://www.makemkv.com/</a>.'
                @_error('license_expired', error)
            else
                callback(code, return_.split(@NEWLINE_CHAR))
        )
    
    ##  Create dir if not exists
    #   @param  str dir Directory to create
    #   @return mixed   false if failed, otherwise new dir
    _mk_dir: (dir) =>
        
        dir = @_sanitize_fn(dir)
        
        try
            stats = fs.lstatSync(dir)
            
            if not stats.isDirectory() #< Path exists, but is normal file
                return false
            
        catch e #< Dir doesn't exist
            
            try
                fs.mkdirSync(dir, @PERMISSIONS['dir'])
            catch e #< Failed to make dir
                return false
            
        dir
        
    ##  Remove reserved characters from file name
    #   @param  file_path   str File path (will sanitize last part)
    #   @return str sanitized
    _sanitize_fn: (out_path) =>
        
        fp = out_path.split('/')
        
        for key, val of @RESERVED_CHAR_MAP
            fp[fp.length - 1] = fp[fp.length - 1].replace(key, val)
        
        console.log('Sanitized fp: ' + fp.join('/'))
        
        fp.join('/') 
        
        
module.exports = MakeMKV