---@diagnostic disable
local entry_maker = require "octo.pickers.fzf-lua.entry_maker"
local fzf = require "fzf-lua"
local gh = require "octo.gh"
local queries = require "octo.gh.queries"
local graphql = require "octo.gh.graphql"
local queries = require "octo.gh.queries"
local picker_utils = require "octo.pickers.fzf-lua.pickers.utils"
local utils = require "octo.utils"
local config = require "octo.config"

local function get_users(query_name, node_name)
  local repo = utils.get_remote_name()
  local owner, name = utils.split_repo(repo)
  local output = gh.api.graphql {
    query = queries[query_name],
    f = { owner = owner, name = name },
    paginate = true,
    jq = ".data.repository." .. node_name .. ".nodes",
    opts = { mode = "sync" },
  }
  if utils.is_blank(output) then
    return {}
  end

  return utils.get_flatten_pages(output)
end

local function get_assignable_users()
  return get_users("assignable_users", "assignableUsers")
end

local function get_mentionable_users()
  return get_users("mentionable_users", "mentionableUsers")
end

-- TODO highlight orgs?
local function format_display(thing)
  return thing.id .. " " .. thing.login
end

return function(cb)
  local cfg = config.values

  -- Handle assignable and mentionable modes with static lists
  if cfg.users == "assignable" or cfg.users == "mentionable" then
    local users = cfg.users == "assignable" and get_assignable_users() or get_mentionable_users()

    if not users or #users == 0 then
      utils.error("No " .. cfg.users .. " users found")
      return
    end

    local formatted_users = {}
    local results = {}
    for _, user in ipairs(users) do
      user.ordinal = format_display(user)
      formatted_users[user.ordinal] = user
      table.insert(results, user.ordinal)
    end

    fzf.fzf_exec(
      results,
      vim.tbl_deep_extend("force", picker_utils.dropdown_opts, {
        fzf_opts = {
          ["--delimiter"] = " ",
          ["--with-nth"] = "2..",
        },
        actions = {
          ["default"] = function(selected)
            local user_entry = formatted_users[selected[1]]
            cb(user_entry.id)
          end,
        },
      })
    )
    return
  end

  -- Handle search mode with live search (original implementation)
  local formatted_users = {}

  local function contents(prompt)
    -- skip empty queries
    if not prompt or prompt == "" or utils.is_blank(prompt) then
      return {}
    end
    local query = graphql("users", prompt[1])
    local output = gh.run {
      args = { "api", "graphql", "--paginate", "-f", string.format("query=%s", query) },
      mode = "sync",
    }
    if output then
      local users = {}
      local orgs = {}
      local responses = utils.get_pages(output)
      for _, resp in ipairs(responses) do
        for _, user in ipairs(resp.data.search.nodes) do
          if not user.teams then
            -- regular user
            if not vim.tbl_contains(vim.tbl_keys(users), user.login) then
              users[user.login] = {
                id = user.id,
                login = user.login,
              }
            end
          elseif user.teams and user.teams.totalCount > 0 then
            -- organization, collect all teams
            if not vim.tbl_contains(vim.tbl_keys(orgs), user.login) then
              orgs[user.login] = {
                id = user.id,
                login = user.login,
                teams = user.teams.nodes,
              }
            else
              vim.list_extend(orgs[user.login].teams, user.teams.nodes)
            end
          end
        end
      end

      local results = {}
      -- process orgs with teams
      for _, user in pairs(users) do
        user.ordinal = format_display(user)
        formatted_users[user.ordinal] = user
        table.insert(results, user.ordinal)
      end
      for _, org in pairs(orgs) do
        org.login = string.format("%s (%d)", org.login, #org.teams)
        org.ordinal = format_display(org)
        formatted_users[org.ordinal] = org
        table.insert(results, org.ordinal)
      end
      return results
    else
      return {}
    end
  end

  fzf.fzf_live(
    contents,
    vim.tbl_deep_extend("force", picker_utils.dropdown_opts, {
      fzf_opts = {
        ["--delimiter"] = " ",
        ["--with-nth"] = "2..",
      },
      actions = {
        ["default"] = {
          function(user_selected)
            local user_entry = formatted_users[user_selected[1]]
            if not user_entry.teams then
              -- user
              cb(user_entry.id)
            else
              local formatted_teams = {}
              local team_titles = {}

              for _, team in ipairs(user_entry.teams) do
                local team_entry = entry_maker.gen_from_team(team)

                if team_entry ~= nil then
                  formatted_teams[team_entry.ordinal] = team_entry
                  table.insert(team_titles, team_entry.ordinal)
                end
              end

              fzf.fzf_exec(
                team_titles,
                vim.tbl_deep_extend("force", picker_utils.dropdown_opts, {
                  actions = {
                    ["default"] = function(team_selected)
                      local team_entry = formatted_teams[team_selected[1]]
                      cb(team_entry.team.id)
                    end,
                  },
                })
              )
            end
          end,
        },
      },
    })
  )
end
