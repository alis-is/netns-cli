---@diagnostic disable: undefined-global, lowercase-global
local _test = TEST or require 'tests.vendor.u-test'
local _netns = require 'netns'

_test['setup - runtimeConfiguration'] = function()
	local _options = _netns.get_default_setup_options()
    _options.publish = {
        {hostAddress = '127.0.0.1', hostPort = '2000', clientPort = '1000', protocol = 'tcp'},
        {hostAddress = '127.0.0.1', hostPort = '3000', clientPort = '2000', protocol = 'udp'}
    }
    _options.masquerade = true
    _options.force = true

    local _runtimeConfig = _netns.setup_netns('test', _options)
	_test.assert(util.equals(_runtimeConfig, _netns.load_runtime_configuration("test"), true))
end

_test['setup - publish'] = function()
    local _options = _netns.get_default_setup_options()
    _options.publish = {
        {hostAddress = '127.0.0.1', hostPort = '2000', clientPort = '1000', protocol = 'tcp'},
        {hostAddress = '127.0.0.1', hostPort = '3000', clientPort = '2000', protocol = 'udp'}
    }
    _options.masquerade = true
    _options.force = true

    local _runtimeConfig = _netns.setup_netns('test', _options)

    for index, v in ipairs(_runtimeConfig.publish) do
        _test.assert(
            _netns.__safe_exec(
                'iptables -t nat -C PREROUTING -p',
                v.protocol,
                '-d',
                v.hostAddress,
                '--dport',
                v.hostPort,
                '-j DNAT --to-destination',
                _runtimeConfig.vecIp .. ':' .. v.clientPort
            ),
            'Rule ' .. tostring(index) .. ' not found!'
        )
    end
end

_test['setup - pre existing no force'] = function()
    local _exitCode = nil
    local _exit = os.exit
    os.exit = function(code)
		_exitCode = code
    end
    local _options = _netns.get_default_setup_options()
    _options.publish = {}
    _options.masquerade = true

    _netns.setup_netns('test', _options)
	os.exit = _exit
	_test.assert(_exitCode == 3)
end

_test['setup - force'] = function()
    local _exitCode = 0
    local _exit = os.exit
    os.exit = function(code)
		_exitCode = code
    end
    local _options = _netns.get_default_setup_options()
    _options.publish = {}
    _options.masquerade = true
    _options.force = true

    _netns.setup_netns('test', _options)
	os.exit = _exit
	_test.assert(_exitCode == 0)
end

_test['setup - nameservers'] = function()
    local _options = _netns.get_default_setup_options()
    _options.publish = {}
    _options.nameservers = { "2.2.2.2", "1.1.1.1" }
    _options.masquerade = true
    _options.force = true

    _netns.setup_netns('test', _options)
    local _ok, _content = fs.safe_read_file("/etc/netns/test/resolv.conf")
    _test.assert(_ok and _content:match("nameserver 2.2.2.2") and _content:match("nameserver 1.1.1.1"))
end

local _runtimeConfigOutboundAddr
_test['setup - outboundAddr'] = function()
    local _options = _netns.get_default_setup_options()
    _options.publish = {}
    _options.outboundAddr = "127.0.0.1"
    _options.force = true

    _runtimeConfigOutboundAddr = _netns.setup_netns('test', _options)

    _test.assert(_netns.__safe_exec("iptables -t nat -C POSTROUTING -s", _runtimeConfigOutboundAddr.vecIp .. "/30", "-j SNAT --to-source", _options.outboundAddr))
end

_test['apply iptables (id)'] = function()
    local _options = _netns.get_default_setup_options()
    _options.outboundAddr = "127.0.0.1"
    _test.assert(_netns.__safe_exec("iptables -t nat -D POSTROUTING -s", _runtimeConfigOutboundAddr.vecIp .. "/30", "-j SNAT --to-source", _options.outboundAddr))
    _test.assert(not _netns.__safe_exec("iptables -t nat -C POSTROUTING -s", _runtimeConfigOutboundAddr.vecIp .. "/30", "-j SNAT --to-source", _options.outboundAddr))
    _netns.apply_iptables('test')
    _test.assert(_netns.__safe_exec("iptables -t nat -C POSTROUTING -s", _runtimeConfigOutboundAddr.vecIp .. "/30", "-j SNAT --to-source", _options.outboundAddr))
end

_test['apply iptables (runtime config)'] = function()
    local _options = _netns.get_default_setup_options()
    _options.outboundAddr = "127.0.0.1"
    local _runtimeConfig = _netns.load_runtime_configuration("test")
    _test.assert(_netns.__safe_exec("iptables -t nat -D POSTROUTING -s", _runtimeConfigOutboundAddr.vecIp .. "/30", "-j SNAT --to-source", _options.outboundAddr))
    _test.assert(not _netns.__safe_exec("iptables -t nat -C POSTROUTING -s", _runtimeConfigOutboundAddr.vecIp .. "/30", "-j SNAT --to-source", _options.outboundAddr))
    _netns.apply_iptables(_runtimeConfig)
    _test.assert(_netns.__safe_exec("iptables -t nat -C POSTROUTING -s", _runtimeConfigOutboundAddr.vecIp .. "/30", "-j SNAT --to-source", _options.outboundAddr))
end

_test['remove'] = function()
    local _options = _netns.get_default_setup_options()
    _options.publish = {}
    _options.outboundAddr = "127.0.0.1"
    _options.force = true

    _netns.remove_netns('test')

    _test.assert(not _netns.__safe_exec("iptables -t nat -C POSTROUTING -s", _runtimeConfigOutboundAddr.vecIp .. "/30", "-j SNAT --to-source", _options.outboundAddr))
end

_test['setup - localhost (false)'] = function()
    local _options = _netns.get_default_setup_options()
    _options.publish = {}
    _options.outboundAddr = "127.0.0.1"
    _options.localhost = false

    _runtimeConfigOutboundAddr = _netns.setup_netns('test', _options)
    _test.assert(_netns.__exec_in_netns("test", "ip a | grep -v 127.0.0.1"))
    _netns.remove_netns('test')
end

if not TEST then
    _test.summary()
end
