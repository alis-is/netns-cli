local _hjson = require"hjson"
local _ip = require"ip"
local _info, _warn, _error, _success = util.global_log_factory("","info", "warn", "error", "success")

local netns = {
	CONFIGURATION_VERSION = 1
}

local function _safe_exec(...)
	local _cmd = string.join(" ", ...)
	_info("Executing: " .. _cmd)
	local _result = proc.exec(_cmd, {
		stdout = "pipe",
		stderr = "pipe"
	})
	if _result.exitcode ~= 0 then
		return false, _result
	end
	return true, _result
end

local function _exec(...)
	local _cmd = string.join(" ", ...)
	local _ok, _result = _safe_exec(_cmd)
	if not _ok then 
		_error("Failed to execute: " .. _cmd)
		if _result.stderrStream ~= nil and type(_result.stderrStream.read) == "function" then
			print(_result.stderrStream:read("a"))
		end
		return os.exit(5)
	end
	return _result
end

---@param id string
local function _exec_in_netns(id, ...)
	return _exec("ip netns exec", id, ...)
end

netns.__exec = _exec
netns.__safe_exec = _safe_exec
netns.__exec_in_netns = _exec_in_netns

---@class PublishDef
---@field hostAddress string
---@field hostPort string|number
---@field clientPort string|number
---@field protocol string

---@class NetnsOptions
---@field publish PublishDef[]
---@field nameservers string[]
---@field masquerade boolean|nil
---@field localhost boolean
---@field force boolean
---@field outboundAddr string|nil
---@field subnet string

---@param id string
---@return string
local function _get_netns_run_file_name(id)
	return "/var/run/" .. id
end

---@param id string
---@return string
local function _get_netns_resolv_conf(id)
	return "/etc/netns/" .. id .. "/resolv.conf"
end

---@param id string
---@return RuntimeConfiguration
function netns.load_runtime_configuration(id)
	local _netnsRunFile = _get_netns_run_file_name(id)
	if not fs.exists(_netnsRunFile) then
		return os.exit(0)
	end
	os.remove(_get_netns_resolv_conf(id))
	local _ok, _rf = fs.safe_read_file(_netnsRunFile)
	if not _ok then 
		_error("Failed to read config file '" .. _netnsRunFile .. "'!")
		return os.exit(4)
	end
	local _ok, _netnsRunConfig = pcall(_hjson.parse, _rf)
	if not _ok then 
		_error("Failed to parse config file '" .. _netnsRunFile .. "'!")
		return os.exit(7)
	end
	if _netnsRunConfig.version ~= netns.CONFIGURATION_VERSION then
		_warn("Invalid runtime configuration version detected: " .. tostring(_netnsRunConfig.version) .. "!")
		return false, _netnsRunConfig
	end
	return true, _netnsRunConfig
end

local function _lock_netns()
	local _lockFile = "/var/run/eli-netns.lockfile"
	if not fs.exists(_lockFile) then
		fs.write_file(_lockFile, "")
	end
	return fs.lock_file(_lockFile, "w")
end

---@param id string
---@param force boolean
function netns.remove_netns(id, force)
	local _valid, _netnsRunConfig = netns.load_runtime_configuration(id)
	if not _valid then
		local _msg = "Invalid runtime configuration version detected: " .. tostring(_netnsRunConfig and _netnsRunConfig.version) .. ". Can not remove!"
		if force then
			_warn(_msg)
			return
		else
			_error(_msg)
			return os.exit(8)
		end
	end

	if _safe_exec("iptables -C FORWARD -s", _netnsRunConfig.vecIp .. "/30", "-j ACCEPT") then
		_safe_exec("iptables -w 60 -D FORWARD -s", _netnsRunConfig.vecIp .. "/30", "-j ACCEPT")
	end
	if _safe_exec("iptables -C FORWARD -d", _netnsRunConfig.vecIp .. "/30", "-j ACCEPT") then
		_safe_exec("iptables -w 60 -D FORWARD -d", _netnsRunConfig.vecIp .. "/30", "-j ACCEPT")
	end
	if _netnsRunConfig.masquerade then
		if _safe_exec("iptables -t nat -C POSTROUTING -s", _netnsRunConfig.vecIp .. "/30", "-j MASQUERADE") then
			_safe_exec("iptables -w 60 -t nat -D POSTROUTING -s", _netnsRunConfig.vecIp .. "/30", "-j MASQUERADE")
		end
	else
		if _safe_exec("iptables -t nat -C POSTROUTING -s", _netnsRunConfig.vecIp .. "/30", "-j SNAT --to-source", _netnsRunConfig.outboundAddr) then
			_safe_exec("iptables -w 60 -t nat -D POSTROUTING -s", _netnsRunConfig.vecIp .. "/30", "-j SNAT --to-source", _netnsRunConfig.outboundAddr)
		end
	end
	for _, v in ipairs(_netnsRunConfig.publish) do
		if _safe_exec("iptables -t nat -C PREROUTING -p", v.protocol, "-d", v.hostAddress, "--dport", v.hostPort, "-j DNAT --to-destination", _netnsRunConfig.vecIp .. ":" .. v.clientPort) then
			_safe_exec("iptables -w 60 -t nat -D PREROUTING -p", v.protocol, "-d", v.hostAddress, "--dport", v.hostPort, "-j DNAT --to-destination", _netnsRunConfig.vecIp .. ":" .. v.clientPort)
		end
	end

	if force then
		_safe_exec("ip netns delete", id)
		_safe_exec("ip link delete", _netnsRunConfig.vehId)
	else 
		_exec("ip netns delete", id)
		_exec("ip link delete", _netnsRunConfig.vehId)
	end
	fs.remove(_get_netns_run_file_name(id))
end

---@class RuntimeConfiguration
---@field id string
---@field vehId string
---@field vecIp string
---@field publish PublishDef[]
---@field outboundAddr string
---@field masquerade boolean

---@param runtimeConfig RuntimeConfiguration|string
function netns.apply_iptables(runtimeConfig)
	local _valid = true
	if type(runtimeConfig) == "string" then
		_valid, runtimeConfig = netns.load_runtime_configuration(runtimeConfig)
	end
	if type(runtimeConfig) ~= "table" or not _valid then
		_error("Invalid options!")
		_info("'--apply-iptables' requires ")
		return os.exit(8)
	end

	if not _safe_exec("iptables -C FORWARD -s", runtimeConfig.vecIp .. "/30", "-j ACCEPT") then
		_exec("iptables -w 60 -I FORWARD -s", runtimeConfig.vecIp .. "/30", "-j ACCEPT")
	end
	if not _safe_exec("iptables -C FORWARD -d", runtimeConfig.vecIp .. "/30", "-j ACCEPT") then
		_exec("iptables -w 60 -I FORWARD -d", runtimeConfig.vecIp .. "/30", "-j ACCEPT")
	end

	if runtimeConfig.masquerade then
		if not _safe_exec("iptables -t nat -C POSTROUTING -s", runtimeConfig.vecIp .. "/30", "-j MASQUERADE") then
			_exec("iptables -w 60 -t nat -I POSTROUTING -s", runtimeConfig.vecIp .. "/30", "-j MASQUERADE")
		end
	else 
		if not _safe_exec("iptables -t nat -C POSTROUTING -s", runtimeConfig.vecIp .. "/30", "-j SNAT --to-source", runtimeConfig.outboundAddr) then
			_exec("iptables -w 60 -t nat -I POSTROUTING -s", runtimeConfig.vecIp .. "/30", "-j SNAT --to-source", runtimeConfig.outboundAddr)
		end
	end

	for _, v in ipairs(runtimeConfig.publish) do
		if not _safe_exec("iptables -t nat -C PREROUTING -p", v.protocol, "-d", v.hostAddress, "--dport", v.hostPort, "-j DNAT --to-destination", runtimeConfig.vecIp .. ":" .. v.clientPort) then
			_exec("iptables -w 60 -t nat -I PREROUTING -p", v.protocol, "-d", v.hostAddress, "--dport", v.hostPort, "-j DNAT --to-destination", runtimeConfig.vecIp .. ":" .. v.clientPort)
		end
	end
end

---@param id string
---@param options NetnsOptions
function netns.setup_netns(id, options)
	local _netnsRunFile = _get_netns_run_file_name(id)
	if fs.exists(_netnsRunFile) then
		if options.force then
			netns.remove_netns(id, options.force)
		else
			_error("Found runtime info about netns '" .. id .. "'.")
			_info("Remove existing runtime info or run with '--force' to automatically cleanup.")
			return os.exit(3)
		end
	end

	local _invalidOutboundAddr = false
	if type(options.outboundAddr) ~= "string" or not options.outboundAddr:match("[^%.]*%.[^%.]*%.[^%.]*%.[^/]*") then 
		_invalidOutboundAddr = true
	end

	-- we keep masquerade only if outbound addr is not specified
	options.masquerade = options.masquerade and _invalidOutboundAddr

	if _invalidOutboundAddr and not options.masquerade then
		_error("Invalid netns outbound addr!")
		return os.exit(2)
	end

	local _hash = hash.sha256sum("veth-"..id, true)
	local _vethId = id:sub(1, 5)
	local _vethhash = _hash:sub(1, 5)
	local _vehId = "veh-" .. _vethId .. _vethhash
	local _vecId = "vec-" .. _vethId .. _vethhash

	-- lock before getting IP range for interfaces
	local _lock
	while _lock == nil do
		_lock, _err = _lock_netns()
		os.sleep(1)
	end

	local _range = _ip.get_next_available_cidr(options.subnet, 30)
	local _vehIp = _ip.n_to_ipv4(_range.__hostMin)
	local _vecIp = _ip.n_to_ipv4(_range.__hostMin + 1)

	local _runtimeConfig = {
		version = netns.CONFIGURATION_VERSION,
		id = id,
		vehId = _vehId,
		vecIp = _vecIp,
		publish = options.publish,
		outboundAddr = options.outboundAddr,
		masquerade = options.masquerade
	}
	if not fs.safe_write_file(_netnsRunFile, _hjson.stringify_to_json(_runtimeConfig)) then
		error("Failed to write runtime config!")
		return os.exit(6)
	end

	_safe_exec("ip netns delete", id)
	local _result = _exec("flock --no-fork -- /var/run/netns.lock ip netns add", id)
	-- patch ubuntu 16.04
	if _result.exitcode == 0 and _result.stderrStream ~= nil and _result.stderrStream:read("a"):match("unrecognized option") then 
		_exec("flock -- /var/run/netns.lock ip netns add", id)
	end

	local _resolvConf = ""
	for _, v in ipairs(options.nameservers) do 
		_resolvConf = _resolvConf .. "nameserver " .. v .. "\n"
	end

	_info("Creating namespaced resolv.conf")
	fs.mkdirp("/etc/netns/" .. id)
	fs.write_file("/etc/netns/" .. id .. "/resolv.conf", _resolvConf)

	_safe_exec("ip link delete", _vehId)
	_exec("ip link add", _vehId, "type veth peer name", _vecId)
	_exec("ip link set", _vecId, "netns" , id)

	_exec("ip addr add", _vehIp .. "/30", "dev", _vehId)
	_exec_in_netns(id, "ip addr add", _vecIp .. "/30", "dev", _vecId)
	if options.localhost ~= false then
		_exec_in_netns(id, "ip link set dev", type(options.localhost) == "string" and options.localhost or "lo", "up")
	end

	_exec("sysctl -w net.ipv4.conf.all.forwarding=1")
	_exec_in_netns(id, "sysctl -w net.ipv4.ip_unprivileged_port_start=0")

	_exec("ip link set", _vehId, "up")
	_exec_in_netns(id, "ip link set", _vecId, "up")
	_exec_in_netns(id, "ip route add default via", _vehIp)
	
	-- unlock when interfaces ready
	_lock:unlock()

	netns.apply_iptables(_runtimeConfig)

	_success("Netns '" .. id .. "' configured.")
	return _runtimeConfig
end

---@return NetnsOptions
function netns.get_default_setup_options()
	return {
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
	
end

return netns