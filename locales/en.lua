Locale = {}

Locale.on_duty            = 'HOBO Auto-Recovery: On Duty (Tow)'
Locale.on_duty_camera     = 'HOBO Auto-Recovery: On Duty (Camera Car)'
Locale.off_duty           = 'HOBO Auto-Recovery: Off Duty'
Locale.duty_wrong_vehicle = 'You must be in a registered tow truck to go on duty.'
Locale.duty_wrong_camera  = 'You must be in a registered camera car to go on duty.'

-- v1.6 — impound duty zones (clock-in + vehicle spawn menus)
Locale.duty_prompt_clock_on  = '[E] Clock On Duty'
Locale.duty_prompt_clock_off = '[E] Clock Off Duty'
Locale.duty_prompt_tow       = '[E] Spawn a Tow Truck'
Locale.duty_prompt_cam       = '[E] Spawn a Camera Car'
Locale.duty_clocked_on       = 'You are now on duty. Spawn a vehicle to start working.'
Locale.duty_denied_role      = 'You do not have the required role to clock on duty.'
Locale.duty_need_clock_in    = 'Clock on duty at the impound first.'
Locale.duty_pad_blocked      = 'The spawn area is blocked — move the vehicle parked on it.'
Locale.duty_menu_tow_title   = 'Spawn Tow Truck'
Locale.duty_menu_cam_title   = 'Spawn Camera Car'
Locale.duty_role_tow         = 'On Duty — Tow Operator'
Locale.duty_role_camera      = 'On Duty — Camera Operator'
Locale.not_in_tow_truck = 'You must be in a tow truck to use the scanner.'
Locale.scan_cooldown    = 'Scanner cooling down. Please wait.'
Locale.no_vehicles      = 'No vehicles in range to scan.'

Locale.scanner_on       = 'Plate scanner activated.'
Locale.scanner_off      = 'Plate scanner deactivated.'
Locale.scanner_duty     = 'You must be on duty to use the plate scanner.'

Locale.repo_alert_title = 'REPO ALERT'
Locale.repo_alert_body  = 'Plate: %s\nOwner: %s\n%s\nReward: $%s'
Locale.repo_accept      = 'Accept Repossession'
Locale.repo_decline     = 'Decline'
Locale.repo_accepted    = 'Repo accepted. Drive to the vehicle location.'
Locale.repo_declined    = 'Repo declined.'
Locale.no_active_repo   = 'You have no active repo job.'

Locale.hookup_prompt    = 'Hook Up Vehicle'
Locale.hookup_start     = 'Securing vehicle...'
Locale.hookup_success   = 'Vehicle secured! Drive to the drop-off zone.'
Locale.hookup_fail      = 'Attachment failed. Try again.'
Locale.not_near_target  = 'Drive closer to the target vehicle.'

Locale.hook_success       = 'Vehicle locked in. Exit your truck and use /secure to attach.'
Locale.secure_exit_truck  = 'Exit your tow truck first, then use /secure.'

Locale.route_to_vehicle  = 'GPS set to repo target.'
Locale.route_to_dropoff  = 'GPS set to drop-off zone: %s'

Locale.detach_prompt    = 'Detach and Complete Repo'
Locale.repo_complete    = 'Repo complete! $%s deposited.'
Locale.repo_fail_api    = 'Failed to log repo to CAD. Payout still processed.'

Locale.owner_notice     = '[REPO NOTICE] Your vehicle (%s) is being repossessed.'

Locale.vehicle_already_attached = 'Vehicle is already attached.'
Locale.hook_initiated            = 'Already hooked — exit your truck and use /secure.'
Locale.hook_wrong_vehicle        = 'You must be in your tow truck to use /hook.'
Locale.hook_not_initiated        = 'Use /hook first while in your tow truck.'
Locale.tow_truck_gone            = 'Tow truck is gone.'
Locale.no_drop_zones             = 'No drop-off zones configured. Check config.lua.'

-- v1.4.3 /hook auto-claim
Locale.not_on_duty               = 'You must be on duty.'
Locale.must_be_in_tow            = 'You must be in your tow truck to use /hook.'
Locale.only_tow                  = 'Only tow drivers can hook.'
Locale.already_claimed           = 'That case is already claimed by another operator.'
Locale.no_vehicle_in_range       = 'No vehicle in range. Drive closer.'

-- Tablet (/towtab)
Locale.tablet_duty       = 'You must be on duty to open the tow tablet.'
Locale.tablet_cad_linked = 'CAD is active — open the Tow Dashboard → Repo Cases.'

-- Camera-car alerts
Locale.camera_alert_title = 'PLATE HIT'
Locale.camera_marker_set  = 'Tow trucks alerted to %s.'
