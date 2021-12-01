local _netns = require"netns"

local _args = cli.parse_args()
local _info, _warn, _error, _success = util.global_log_factory("", "info", "warn", "error", "success")

local _options = {
	publish = {},
	subnet = "172.29.0.0/16",
	nameservers = { "1.1.1.1", "8.8.8.8" },
	subnet6 = "",
	setup = nil,
	remove = nil,
	["apply-iptables"] = nil,
	masquerade = false,
	localhost = false
}

local function _validate_id(id)
	if type(id) ~= "string" or #id < 4 then
		_error("Invalid netns ID!")
		_info("Got '".. tostring(id) .."' of type '".. type(id).. "'. Requires string of length >= 4.")
		os.exit(1)
	end
end

for _, v in ipairs(_args) do
    if v.type == "option" then
		if v.id == "setup" then 
			_validate_id(v.value)
			_options.setup = v.value
		elseif v.id == "outbound-addr" then 
			_options.outboundAddr = v.value
		elseif v.id == "publish" or v.id == "p"then
			local _val = v.value
			local _,n = _val:gsub(":","")
			if n < 1 or n > 2 then 
				_warn("Invalid port map " .. _val)
				goto CONTINUE
			end
			local _hAddr, _hport, _cport, _proto 
			if n == 1 then 
				_hport, _cport, _proto = _val:match"([^:]*):([^/]*)/?(.*)"
				_hAddr = "0.0.0.0/0"
			else 
				_hAddr, _hport, _cport, _proto = _val:match"([^:]*):([^:]*):([^/]*)/?(.*)"
			end
			if _proto == nil or _proto == "" then _proto = "tcp" end
			---@type PublishDef
			local _publishDef = { hostAddress = _hAddr, clientPort = _cport, hostPort = _hport, protocol = _proto }
			table.insert(_options.publish, _publishDef)
		elseif v.id == "subnet" then 
			_options.subnet = v.value
		elseif v.id == "nameservers" or v.id == "ns" then
			local _nameservers = {}
			for w in string.gmatch(v.value, "[^,]*") do
				table.insert(_nameservers, w)
			end
			if #_nameservers > 0 then 
				_options.nameservers = _nameservers
			end
		elseif v.id == "default-outbound-addr" or v.id == "masquerade" then
			_options.masquerade = true
		elseif v.id == "remove" then
			_validate_id(v.value)
			_options.remove = v.value
		elseif v.id == "apply-iptables" then
			_validate_id(v.value)
			_options["apply-iptables"] = v.value
		elseif v.id == "localhost" then
			if type(v.value) == "string" then
				_options.localhost = v.value
			else
				_options.localhost = true
			end
		elseif v.id == "force" then
			_options.force = true
		end
	end
	::CONTINUE::
end

if _options.remove then 
	_netns.remove_netns(_options.remove, _options.force)
end

if _options["apply-iptables"] then
	_netns.apply_iptables(_options["apply-iptables"])
end

if _options.setup then
	_netns.setup_netns(_options.setup, _options)
end
