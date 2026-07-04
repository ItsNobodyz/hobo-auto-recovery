fx_version 'cerulean'
game 'gta5'

author 'HOBO CAD'
description 'HOBO Auto-Recovery — FiveM repossession system with optional HOBO CAD integration'
version '1.6'

lua54 'yes'

dependencies {
    '/server:5000',
    'ox_lib'
}

optional_dependencies {
    'hobo-notify'
}

ui_page 'web/index.html'

files {
    'web/index.html',
    'web/style.css',
    'web/app.js',
    'web/tablet.css',
    'web/tablet.js',
    'web/sounds/fl.wav',
    'web/sounds/fr.wav',
    'web/sounds/rl.wav',
    'web/sounds/rr.wav',
    'postals.json',
}

server_scripts {
    'hmac_helper.js',
    'config.lua',
    'shared/bridge.lua',
    'shared/randomdata.lua',
    'server/payments.lua',
    'server/spawner.lua',
    'server/main.lua',
    'server/updater.lua',
    'server/duty.lua'
}

client_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/bridge.lua',
    'client/location.lua',
    'client/main.lua',
    'client/duty.lua',
    'client/scanner.lua',
    'client/ambush.lua',
    'client/minigame.lua',
    'client/dropoff.lua',
    'client/tablet.lua',
}

shared_scripts {
    'locales/en.lua'
}
