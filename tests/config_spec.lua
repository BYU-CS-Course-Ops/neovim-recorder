local T = _G.TEST
local config = require('code-recorder.config')

T.describe('config', function()
    T.it('defaults to the shared extension whitelist', function()
        config.reset()
        T.assert_same({ '.py', '.h', '.hpp', '.cpp', '.java' }, config.get().tracked_extensions)
    end)

    T.it('replaces the extension list rather than merging it', function()
        config.setup({ tracked_extensions = { '.py' } })
        T.assert_same({ '.py' }, config.get().tracked_extensions)
        config.reset()
    end)

    T.it('replaces roots rather than merging them', function()
        config.setup({ roots = { '/a' } })
        T.assert_same({ '/a' }, config.get().roots)
        config.reset()
    end)

    T.it('keeps unspecified defaults', function()
        config.setup({ auto_start = true })
        T.assert_equal(true, config.get().auto_start)
        T.assert_equal(1000, config.get().batch_idle_ms)
        config.reset()
    end)

    T.it('restores defaults on reset', function()
        config.setup({ batch_idle_ms = 5 })
        config.reset()
        T.assert_equal(1000, config.get().batch_idle_ms)
    end)
end)
