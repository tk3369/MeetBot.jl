module MeetBot

using Discord
using Discord: Snowflake
using Dates: now, DateTime, TimePeriod, Second, Minute, Hour
using Base.Threads: SpinLock
using UUIDs: uuid4

const PREFIX = "!"

const QUEUE = Channel(100)
const MEET_GROUP = Dict()
const MEET_GROUP_LOCK = SpinLock()

const MEET_CHANNELS = Set()
const MEET_CHANNELS_LOCK = SpinLock()

mutable struct MeetRequest
    guild_id::Snowflake
    user::User
    queue_time::DateTime
    notify1::Bool
    notify2::Bool
end

struct MeetChannel
    channel_id::Snowflake
    created_time::DateTime
    name::String
end

Base.@kwdef struct Config
    meet_channel_lifetime::TimePeriod
    time_to_notify1::TimePeriod
    time_to_notify2::TimePeriod
    time_to_delete_request::TimePeriod
end

function get_config()
    if get(ENV, "MEETBOT_ENV", "DEV") == "DEV"
        return Config(
            meet_channel_lifetime = Minute(10),
            time_to_notify1 = Second(5),
            time_to_notify2 = Second(15),
            time_to_delete_request = Minute(1),
        )
    else
        return Config(
            meet_channel_lifetime = Hour(2),
            time_to_notify1 = Minute(5),
            time_to_notify2 = Minute(30),
            time_to_delete_request = Hour(2),
        )
    end
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

"Create a new meet request after user confirms they want to meetup."
function confirmation_command(c::Client, m::Message)
    @info "Meetup confirmation command"
    request = MeetRequest(m.guild_id, m.author, now(), false, false)
    put!(QUEUE, request)
    username = m.author.username
    reply(c, m, "Hey, $(username), you have been added to the meetup queue. Stay tuned...")
end

"""
Introductory command that shows the other commands
"""
function meet_command(c::Client, m::Message)
    @info "Meetbot's introductory command"
    uid = m.author.id
    text = "<@$(uid)>, Thank you for using MeetBot! To begin meeting new people, type **!confirm** to be added to the meetup queue or if you want to leave the queue, type **!quit**."
    reply(c, m, text)
end

function quit_command(c::Client, m::Message)
    @info "Remove a person waiting in queue if they choose to leave"
    text = "Sad to see you leave, but you have been removed from the queue."
    cancel_request(MEET_GROUP[m.author.id])
    reply(c, m, text)
end

function process_meet_requests(c::Client)
    @info "Starting process_meet_requests"
    while true
        request = take!(QUEUE)

        @info "process_meet_requests: got request" request
        register_request(request)
        if length(MEET_GROUP) == 4  # should be 4
            channel = create_voice_channel(c, request.guild_id)
            notify_meet_group(channel, c)
            empty_meet_group()
        end
    end
end

"Return the current requests pending in the meet group."
current_requests() = collect(values(MEET_GROUP))

"""
Find Meetup category.
"""
function find_meetup_category(c::Client,  guild_id::Snowflake)
    channels = fetchval(Discord.get_guild_channels(c, guild_id))
    idx = findfirst(x -> x.type == CT_GUILD_CATEGORY && x.name == "Meetup", channels)
    return idx !== nothing ? channels[idx].id : nothing
end

"""
Ensure that a Meetup category channel is created. 
Return the category's channel id.
"""
function ensure_meetup_category(c::Client,  guild_id::Snowflake)
    category_id = find_meetup_category(c, guild_id)
    if category_id === nothing
        guild = fetchval(get_guild(c, guild_id))
        category_channel = fetchval(create(c, DiscordChannel, guild; 
            name="Meetup", type=CT_GUILD_CATEGORY))
        category_id = category_channel.id
    end
    return category_id
end

"Create a new voice channel"
function create_voice_channel(c::Client, guild_id::Snowflake)
    @info "Alright, let's create a new voice channel."
    lock(MEET_CHANNELS_LOCK) do 
        category_id = ensure_meetup_category(c, guild_id)

        # get user ids from MEET_`GROUP
        uids = keys(MEET_GROUP)
        @info "User id's in MEET_GROUP" uids

        # Create an overwrite object for each user in the meet group
        overwrite_arr = []
        for id in uids
            new_overwrite = Overwrite(id, OT_MEMBER, Int(PERM_VIEW_CHANNEL), 0)
            push!(overwrite_arr, new_overwrite)
        end

        #Create overwrite object for everyone to prevent anyone else from seeing it
        everyone_id = find_id(c, guild_id, "@everyone")
        @info "@everyone id" everyone_id
        everyone_overwrite = Overwrite(everyone_id, OT_ROLE, 0, Int(PERM_VIEW_CHANNEL))
        push!(overwrite_arr, everyone_overwrite)

        # Create the voice channel/push to MEET_CHANNELS
        room_name = "Meetup Room " * string(uuid4())[1:6]
        guild = fetchval(get_guild(c, guild_id))
        
        vc = fetchval(create(c, DiscordChannel, guild;
            name = room_name, 
            type = CT_GUILD_VOICE,
            parent_id = category_id, 
            permission_overwrites = overwrite_arr))
        @info "Created voice channel" vc

        mc = MeetChannel(vc.id, now(), room_name)
        push!(MEET_CHANNELS, mc)

        return mc
    end
end

# helper function that finds the id of the given role
function find_id(c::Client, guild_id, role)
    role_lst = fetchval(get_guild_roles(c, guild_id))
    @info role_lst
    for r in role_lst
        if r.name == role
            return r.id
        end
    end
    throw(MissingException("role not found"))
end

"""
Send DM to participants of the current meet group and ask them
to join the voice channel.
"""
function notify_meet_group(mc::MeetChannel, c::Client)
    for request in current_requests()
        content = "Hey $(request.user.username), thanks for waiting! 
        Please join <#" * string(mc.channel_id) * ">"
        dm = fetchval(create_dm(c; recipient_id = request.user.id))
        create_message(c, dm.id; content=content)
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
function notify_participant(c::Client, request, notify_count)
    if notify_count == 1
        message = "I know, you've been waiting for a while. Please be patient."
    else
        message = "Unfortunately, we are still waiting for someone to meet up. We will let you know once it's available."
    end
    @info "Sending DM to $(request.user.username)" message now()
    dm = fetchval(create_dm(c; recipient_id = request.user.id))
    create_message(c, dm.id; content = message)
end

"""
Check meet group. For each participant:
1. Send a DM when the person has waited over 2 mins (be patient)
2. Send a DM when the person has waited over 15 mins (be patient)
3. Send a DM & cancel request when the person has waited over an hour
"""
function check_meet_group(c::Client)
    cfg = get_config()
    @info "Starting check_meet_group" cfg
    try
        while true
            requests = current_requests()
            if length(requests) > 0
                current_time = now()
                foreach(requests) do request
                    elapsed = current_time - request.queue_time
                    if elapsed > cfg.time_to_delete_request
                        cancel_request(request)
                    elseif elapsed > cfg.time_to_notify2
                        !request.notify2 && notify_participant(c, request, 2)
                        request.notify2 = true
                    elseif elapsed > cfg.time_to_notify1
                        !request.notify1 && notify_participant(c, request, 1)
                        request.notify1 = true
                    end
                end
            end
            sleep(1)
        end
    catch ex
        @info "check_meet_group stopped due to $(ex)" now()
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
function gc_meet_channels(c::Client)
    cfg = get_config()
    try
        while true
            current_time = now()
            @info "gc_meet_channels" current_time
            lock(MEET_CHANNELS_LOCK) do
                old_meet_channels = filter(MEET_CHANNELS) do mc
                    current_time - mc.created_time > cfg.meet_channel_lifetime
                end
                foreach(old_meet_channels) do mc
                    @info "Deleting channel" mc
                    delete_channel(c, mc.channel_id)
                    delete!(MEET_CHANNELS, mc)
                end
            end
            sleep(60)
        end
    catch ex
        @info "gc_meet_channels stopped due to $(ex)" now()
    end
end

# For development only, do not use otherwise.
function get_client()
    token = get_discord_token()
    c = Client(token; 
        prefix = PREFIX, 
        presence=(game=(name="MeetBot", type=AT_GAME),))
    open(c)
    @info "Try fetchval(Discord.get_current_user_guilds(c))"
    return c
end

function run()
    token = get_discord_token()
    c = Client(token; prefix = PREFIX, presence=(game=(name="MeetBot", type=AT_GAME),))

    add_command!(c, :shutdown, shutdown_command; help="shutdown bot")
    add_command!(c, :confirm, confirmation_command; help="enter person into meetup queue")
    add_command!(c, :meet, meet_command; help="give information about how meetbot works")
    add_command!(c, :quit, quit_command; help="removes a user from queue if they choose to leave")

    open(c)
    @info "Connected to client" c

    # background tasks
    @async process_meet_requests(c)
    meet_group_checker_task = @async check_meet_group(c)
    gc_meet_channels_task = @async gc_meet_channels(c)

    wait(c)
    @info "Disconnected Discord client"
    
    schedule(meet_group_checker_task, InterruptException(); error = true)
    schedule(gc_meet_channels_task, InterruptException(); error = true)

    return nothing
end

end