--[[

License: https://github.com/CrendKing/mpv-twitch-chat/blob/master/LICENSE

Options:

    show_name: Whether to show the commenter's name.

    color: If show_name is enabled, color the commenter's name with its user color. Otherwise, color the whole message.

    duration_multiplier: Each chat message's duration is calculated based on the density of the messages at the time after
        applying this multiplier. Basically, if you want more messages simultaneously on screen, increase this number.

    max_duration: Maximum duration in seconds of each chat message after applying the previous multiplier. This exists to prevent
        messages to stay forever in "cold" segments.

    fetch_aot: The chat data is downloaded in segments. This script uses timer to fetch new segments this many seconds before the
        current segment is exhausted. Increase this number to avoid interruption if you have slower network to Twitch.

--]]

local o = {
    show_name = true,
    color = true,
    duration_multiplier = 12,
    max_duration = 20,
    fetch_aot = 5
}

local options = require 'mp.options'
options.read_options(o)

if not mp.get_script_directory() then
    mp.msg.error("This script requires to be placed in a script directory")
    return
end

local utils = require "mp.utils"
package.path = utils.join_path(utils.join_path(mp.get_script_directory(), "json.lua"), "json.lua;") .. package.path
local json = require "json"

table.filter = function(t, filterIter)
    local out = {}
  
    for k, v in pairs(t) do
        if filterIter(v, k, t) then table.insert(out,v) end
    end
  
    return out
end

local function filter_comments(o, k, i)
    -- local emote = 0
    -- for j, v in ipairs(o.message.fragments) do
    --     if v.emoticon then
    --         emote = emote +1
    --     end
    -- end
    if string.find(o.message.body, "gifted a Tier %d sub to")~=nil then
        return false
    elseif #o.message.body>200 then
        return false
    -- elseif o.message.fragments then
    --     -- body
    else
        return true
    end
end

local function format_comment(comment)
    if comment.message.user_badges~=nil then
        local vip = false
        for key, value in ipairs(comment.message.user_badges) do
            if value._id=='moderator' then
                comment.commenter.display_name = '+'..comment.commenter.display_name
                vip = true
            end
            if value._id=='vip' then
                vip = true
            end
        end
        if vip then
            comment.commenter.display_name = [[{\b1}]]..comment.commenter.display_name..[[{\b0}]]
        end
    end
    return comment
end

table.tostring = function(tbl)
    local result = "{"
    for k, v in pairs(tbl) do
        -- Check the key type (ignore any numerical keys - assume its an array)
        if type(k) == "string" then
            result = result.."[\""..k.."\"]".."="
        end

        -- Check the value type
        if type(v) == "table" then
            result = result..table_to_string(v)
        elseif type(v) == "boolean" then
            result = result..tostring(v)
        else
            result = result.."\""..v.."\""
        end
        result = result..","
    end
    -- Remove leading commas from the result
    if result ~= "{" then
        result = result:sub(1, result:len()-1)
    end
    return result.."}"
end

-- sid to be operated on
local chat_sid
-- request url for the chat data
local twitch_comments_url
-- next segment ID to fetch from Twitch
local twitch_cursor
-- two fifo segments for cycling the subtitle text
local curr_segment
local next_segment
-- SubRip sequence counter
local seq_counter
local ass_header
-- timer to fetch new segments of the chat data
local timer

ass_header = [[[Script Info]
Title: Twitch Chat
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 0
ScaledBorderAndShadow: yes
YCbCr Matrix: None

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Twitch,Source Sans Pro,30,&H00FFFFFF,&H000000FF,&H7D000000,&H00474747,0,0,0,0,100,100,0,0,1,0,0.8,9,10,20,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
]]

local function load_twitch_chat(is_new_session)
    
    if not chat_sid or not twitch_comments_url then
        return
    end

    local request_url
    if is_new_session then
        local time_pos = mp.get_property_native("time-pos")
        if not time_pos then
            return
        end

        request_url = twitch_comments_url .. "?content_offset_seconds=" .. math.max(time_pos, 0)
        next_segment = ''
        seq_counter = 0
    else
        request_url = twitch_comments_url .. "?cursor=" .. twitch_cursor
    end
    
    
    local sp_ret = mp.command_native({
        name = "subprocess",
        capture_stdout = true,
        args = {"curl", "-s", "-H", "Client-ID: phiay4sq36lfv9zu7cbqwz2ndnesfd8", request_url},
    })
    if sp_ret.status ~= 0 then
        mp.msg.error("Error curl exit code: " .. sp_ret.status)
        return
    end

    local resp_json = json.decode(sp_ret.stdout)
    local comments = resp_json.comments
    if not comments then
        mp.msg.error("Failed to download comments JSON: " .. sp_ret.stdout)
        return
    end

    twitch_cursor = resp_json._next
    curr_segment = next_segment
    next_segment = ""

    comments = table.filter(comments, filter_comments)

    local last_msg_offset = comments[#comments].content_offset_seconds
    local segment_duration = last_msg_offset - comments[1].content_offset_seconds
    local per_msg_duration = math.min(segment_duration * o.duration_multiplier / #comments, o.max_duration)

    for i, curr_comment in ipairs(comments) do
        local msg_time_from = curr_comment.content_offset_seconds
        local msg_time_from_ms = math.floor(msg_time_from * 1000) % 1000
        local msg_time_from_sec = math.floor(msg_time_from) % 60
        local msg_time_from_min = math.floor(msg_time_from / 60) % 60
        local msg_time_from_hour = math.floor(msg_time_from / 3600)

        local msg_time_to = msg_time_from + per_msg_duration
        local msg_time_to_ms = math.floor(msg_time_to * 1000) % 1000
        local msg_time_to_sec = math.floor(msg_time_to) % 60
        local msg_time_to_min = math.floor(msg_time_to / 60) % 60
        local msg_time_to_hour = math.floor(msg_time_to / 3600)

        local msg_part_1, msg_part_2, msg_separator
        if o.show_name then
            curr_comment = format_comment(curr_comment)
            msg_part_1 = curr_comment.commenter.display_name
            msg_part_2 = curr_comment.message.body
            msg_separator = ": "
        else
            msg_part_1 = curr_comment.message.body
            msg_part_2 = ""
            msg_separator = ""
        end
        if o.color then
            local msg_color
            local msg_color_bgr
            if curr_comment.message.user_color then
                -- rand = false
                msg_color = string.sub(curr_comment.message.user_color, 2)
            else
                -- rand = true
                msg_color = string.format("%06x", curr_comment.commenter._id % 16777216)
            end
            msg_color_bgr = string.sub(msg_color, 5, 6) .. string.sub(msg_color, 3, 4) .. string.sub(msg_color, 1, 2)
            msg_part_1 = string.format([[{\c&H%s&\3a&HF0&\4c&H000000&}%s{\c&HFFFFFF&\3a&H7D&\4c&H474747&}]], msg_color_bgr, msg_part_1)
            -- msg_part_2 = string.format("%s %s ", msg_color, rand) .. msg_part_2
        end

        local msg_line = msg_part_1 .. msg_separator .. msg_part_2

        local subtitle = string.format([[Dialogue: 0,%s:%s:%s.%s,%s:%s:%s.%s,Twitch,,0,0,0,,%s
]],
            msg_time_from_hour, msg_time_from_min, msg_time_from_sec, msg_time_from_ms,
            msg_time_to_hour, msg_time_to_min, msg_time_to_sec, msg_time_to_ms,
            msg_line)
        next_segment = next_segment .. subtitle
        seq_counter = seq_counter + 1
    end

    mp.command_native({"sub-remove", chat_sid})
    mp.command_native({
        name = "sub-add",
        url = "memory://" .. ass_header .. curr_segment .. next_segment,
        title = "Twitch Chat"
    })
    chat_sid = mp.get_property_native("sid")

    return last_msg_offset
end

local function init()
    twitch_comments_url = nil
end

local function timer_callback(is_new_session)
    local last_msg_offset = load_twitch_chat(is_new_session)
    if last_msg_offset then
        local fetch_delay = last_msg_offset - mp.get_property_native("time-pos") - o.fetch_aot
        timer = mp.add_timeout(fetch_delay, function()
            timer_callback(false)
        end)
    end
end

local function handle_track_change(name, sid)
    if not sid and timer then
        timer:kill()
        timer = nil
    elseif sid and not timer then
        if not twitch_comments_url then
            local sub_filename = mp.get_property_native("current-tracks/sub/external-filename")
            twitch_comments_url = sub_filename and sub_filename:match("https://api.twitch.tv/v5/videos/%d+/comments") or nil
        end

        if twitch_comments_url then
            chat_sid = sid
            timer_callback(true)
        end
    end
end

local function handle_seek(event)
    if mp.get_property_native("sid") then
        load_twitch_chat(true)
    end
end

local function handle_pause(name, paused)
    if timer then
        if paused then
            timer:stop()
        else
            timer:resume()
        end
    end
end


-- mp.add_key_binding("shift+alt+left", name|fn [,fn [,flags]])
-- mp.add_key_binding("shift+alt+right", name|fn [,fn [,flags]])
-- mp.add_key_binding("shift+alt+up", name|fn [,fn [,flags]])
-- mp.add_key_binding("shift+alt+down", name|fn [,fn [,flags]])

mp.register_event("start-file", init)
mp.observe_property("current-tracks/sub/id", "native", handle_track_change)
mp.register_event("seek", handle_seek)
mp.observe_property("pause", "native", handle_pause)
