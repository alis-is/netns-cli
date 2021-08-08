local ip = {}

local function _join(separator, ...)
    local _result = ""
    if type(separator) ~= "string" then
        separator = ""
    end
    for _, v in ipairs(table.pack(...)) do
        if #_result == 0 then
            _result = tostring(v)
        else
            _result = _result .. separator .. tostring(v)
        end
    end
    return _result
end

function ip.n_to_ipv4(addr)
	assert(math.floor(addr) == addr and addr >= 0, "Invalid ipv4!")
	local ipv4 = {}
	local _addr = addr 
	for i = 1, 4, 1 do
		local _o = _addr & 255
		table.insert(ipv4, 1, _o)
		_addr = _addr >> 8
	end
	return _join(".", table.unpack(ipv4))
end

local function _get_cidr(cidr)
	local _errMsg = "Invalid cidr"
	local _, n = cidr:gsub("%.", "");
	assert(n == 3, _errMsg)
	assert(cidr:match("/"), _errMsg)
	local _o1, _o2, _o3, _o4, _mask = cidr:match("([^%.]*)%.([^%.]*)%.([^%.]*)%.([^/]*)/(.*)")

	local _ip = 0
	for _, v in ipairs(table.pack(_o1, _o2, _o3, _o4)) do
		local _o = tonumber(v)
		assert(_o ~= nil and _o < 256 and _o >= 0, _errMsg)
		_ip = (_ip << 8) + _o
	end
	local _mask = tonumber(_mask)
	assert(_mask ~= nil and _mask >= 0 and _mask <= 32)

	local _maskBin = string.rep("1", _mask) .. string.rep("0", 32 - _mask)
	local _networkAddr = _ip & tonumber(_maskBin, 2)
	local _broadcastAddr = 32 - _mask > 0 and _networkAddr | tonumber(string.rep("1", 32 - _mask), 2) or _networkAddr

	local _hostMin, _hostMax
	if _networkAddr + 1 < _broadcastAddr then 
		_hostMin = _networkAddr + 1
		_hostMax = _broadcastAddr - 1
	end

	return {
		network = ip.n_to_ipv4(_networkAddr),
		broadcast = ip.n_to_ipv4(_broadcastAddr),
		host_range = _networkAddr + 1 < _broadcastAddr and ip.n_to_ipv4(_hostMin) .. " - " .. ip.n_to_ipv4(_hostMax) or "-",
		__network = _networkAddr,
		__broadcast = _broadcastAddr,
		__hostMin = _hostMin,
		__hostMax = _hostMax
	}
end

local function _is_overlap(cidr1, cidr2)
	return (cidr1.__network <= cidr2.__network and cidr1.__broadcast <= cidr2.__broadcast and cidr1.__broadcast >= cidr2.__network) or 
		(cidr1.__network >= cidr2.__network and cidr1.__network <= cidr2.__broadcast and cidr1.__broadcast >= cidr2.__broadcast) or
		(cidr1.__network >= cidr2.__network and cidr1.__broadcast <= cidr2.__broadcast) or
		(cidr1.__network <= cidr2.__network and cidr1.__broadcast >= cidr2.__broadcast)
end

local function _get_next_available_cidr(fromRange, targetMask, used)
	if type(used) ~= "table" then 
		used = {}
	end
	local _fromCidr = _get_cidr(fromRange)
	local _candidateCidr = _get_cidr(_fromCidr.network .. "/" .. targetMask)
	while true do
		for pos, _usedRange in ipairs(used) do 
			local _usedCidr = _get_cidr(_usedRange)
			if _is_overlap(_candidateCidr, _usedCidr) then
				-- within -> 
				local _next = math.max(_candidateCidr.__broadcast, _usedCidr.__broadcast) + 1
				_candidateCidr = _get_cidr(ip.n_to_ipv4(_next) .. "/" .. targetMask)
				table.remove(used, pos)
				goto CONTINUE
			end
		end
		break
		::CONTINUE::
	end
	return _candidateCidr
end

local function _exec(...)
	local _cmd = string.join(" ", ...)
	return proc.exec(_cmd, {
		stdout = "pipe",
		stderr = "pipe"
	})
end

function ip.get_next_available_cidr(subnet, targetMask)
	local _result = _exec("ip -4 a")
	local _output = _result.stdoutStream:read("a")
	local _usedIpRanges = {}
	for _ipRange in _output:gmatch("%S*%.%S*%.%S*%.%S*/%S*") do
		table.insert(_usedIpRanges, _ipRange)
	end
	return _get_next_available_cidr(subnet, targetMask, _usedIpRanges)
end

return ip