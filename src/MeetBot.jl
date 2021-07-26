module MeetBot

using Discord
using Dates: now, DateTime, Second, Minute
using Base.Threads: SpinLock

const PREFIX = ","

const QUEUE = Channel(100)
const MEET_GROUP = Dict()
const MEET_GROUP_LOCK = SpinLock()

const MEET_CHANNELS = Set()
const MEET_CHANNELS_LOCK = SpinLock()

mutable struct MeetRequest
    user::User
    queue_time::DateTime
    notify1::Bool
    notify2::Bool
end

"Shut down bot. This can be used by specific people only."
function shutdown_command(c::Client, m::Message)
    if m.author.id in (0x079fc5a25082000b, 0x04989e135042000b)
        @info "Shutting down, please wait..." now()
        close(c)
    else
        @warn "Unauthorized shutdown command" m.author now()
    end
end

"Create a new meet request."
function meet_command(c::Client, m::Message)
    @info "Meet command"
    request = MeetRequest(m.author, now(), false, false)
    put!(QUEUE, request)
    username = m.author.username
    reply(c, m, "Hey, $(username), you have been added to the meetup queue. Stay tuned...")
end

function process_meet_requests(c::Client)
    @info "Starting process_meet_requests"
    while true
        request = take!(QUEUE)

        @info "process_meet_requests: got request" request
        register_request(request)
        if length(MEET_GROUP) == 3  # should be 4
            channel = create_voice_channel(c)
            notify_meet_group(channel)
            empty_meet_group()
        end
    end
end

"Return the current requests pending in the meet group."
current_requests() = collect(values(MEET_GROUP))

"Create a new voice channel"
function create_voice_channel(c::Client)
    @info "Alright, let's create a new voice channel."
    lock(MEET_CHANNELS_LOCK) do 
        # TODO create a channel and push! to MEET_CHANNELS
        guild_arr = fetchval(get_current_user_guilds(c))
        guild = first(guild_arr)
        room_count = length(MEET_CHANNELS) + 1
        if room_count == 1
            global category_id = fetchval(create(c, DiscordChannel, guild; name="Meetup", type=CT_GUILD_CATEGORY)).id
        end

        uids = keys(MEET_GROUP)
        overwrite_arr = []
        for id in uids
            new_overwrite = Overwrite(id, OT_MEMBER, Int(PERM_VIEW_CHANNEL), 0)
            append!(overwrite_arr, new_overwrite)
        end
        vc = fetchval(create(c, DiscordChannel, guild; name="Meetup Room "*string(room_count), 
        type=CT_GUILD_VOICE, parent_id=category_id, permission_overwrites=overwrite_arr))
        room_count+=1
        push!(MEET_CHANNELS, vc)

        # Return a channel object
        return vc
    end
end

"""
Send DM to participants of the current meet group and ask them
to join the voice channel.
"""
function notify_meet_group(channel)
    for request in current_requests()
        @info "Hey $(request.user.username), please join $channel" #TODO
    end
end

"Register a request for meet-up"
function register_request(request)
    user_id = request.user.id
    lock(MEET_GROUP_LOCK) do
        if haskey(MEET_GROUP, user_id)
            @warn "User is already registered $(user_id)"
        else
            MEET_GROUP[user_id] = request
        end
    end
end

"Cancel an already registered request"
function cancel_request(request)
    @info "Cancelling request" request now()
    lock(MEET_GROUP_LOCK) do
        pop!(MEET_GROUP, request.user.id)
    end
    return nothing
end

"""
Empty the current meet group. This should be called after the current
meet group has been processed (i.e. a voice chat has been prepared).
"""
function empty_meet_group()
    @info "Emptying meet group"
    lock(MEET_GROUP_LOCK) do
        empty!(MEET_GROUP)
    end
end

"Send DM to user and tell them to be patient"
function notify_participant(request)
    message = "I know, you've been waiting for a while. Please be patient."
    @info "Sending DM to $(request.user.username)" message now() #TODO
end

"""
Check meet group. For each participant:
1. Send a DM when the person has waited over 2 mins (be patient)
2. Send a DM when the person has waited over 15 mins (be patient)
3. Send a DM & cancel request when the person has waited over an hour
"""
function check_meet_group()
    time_to_first_reminder = Second(5) #Minute(2)
    time_to_second_reminder = Second(15) #Minute(15)
    time_to_delete = Minute(1) #Minute(60)
    @info "Starting check_meet_group" time_to_first_reminder time_to_second_reminder time_to_delete
    try
        while true
            requests = current_requests()
            if length(requests) > 0
                current_time = now()
                foreach(requests) do request
                    elapsed = current_time - request.queue_time
                    if elapsed > time_to_delete
                        cancel_request(request)
                    elseif elapsed > time_to_second_reminder
                        !request.notify2 && notify_participant(request)
                        request.notify2 = true
                    elseif elapsed > time_to_first_reminder
                        !request.notify1 && notify_participant(request)
                        request.notify1 = true
                    end
                end
            end
            sleep(1)
        end
    catch ex
        @info "check_meet_group stopped due to $(ex)"
    end
end

"Retrieve the Discord bot token from environment."
function get_discord_token()
    env_var = "DISCORD_MEETBOT_TOKEN"
    if haskey(ENV, env_var) && length(ENV[env_var]) > 50
        return ENV[env_var]
    else
        error("You must set up `$env_var` ennvironment variable.")
    end
end

"Garbage collect meet channels when they are too old and nobody inside"
function gc_meet_channels()
    lock(MEET_CHANNELS_LOCK) do 
        # TODO delete old meet channels
    end
end

# For development only, do not use otherwise.
function get_client()
    token = get_discord_token()
    c = Client(token; 
        prefix = PREFIX, 
        presence=(game=(name="MeetBot", type=AT_GAME),))
    open(c)
    @info "Try fetch(Discord.get_current_user_guilds(c)).val"
    return c
end

function run()
    token = get_discord_token()
    c = Client(token; prefix = PREFIX, presence=(game=(name="MeetBot", type=AT_GAME),))

    add_command!(c, :shutdown, shutdown_command; help="shutdown bot")
    add_command!(c, :meet, meet_command; help="meet someone")

    open(c)
    @info "Connected to client" c

    # background task
    meet_group_checker_task = @async check_meet_group()
    @async process_meet_requests(c)

    wait(c)
    @info "Disconnected Discord client"
    schedule(meet_group_checker_task, InterruptException(); error = true)

    return nothing
end

end