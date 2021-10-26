local _eliNet = require "eli.net"
local _eliFs = require "eli.fs"
U_TEST_FILE = "tests/tmp/u-test.lua"

if _eliFs.exists(U_TEST_FILE) then
    print "u-test found"
else
    print "downloading u-test"
    local _ok, _error =
        _eliNet.safe_download_file("https://raw.githubusercontent.com/cryi/u-test/master/u-test.lua", U_TEST_FILE)
    assert(_ok, "Failed to download u-test " .. tostring(_error))
end

return dofile(U_TEST_FILE)
