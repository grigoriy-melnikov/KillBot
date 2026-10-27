<?php
// TEMPLATE ONLY. verification.php does not load this file.
// Overwritten on every kb_install update.
// Copy new keys from here into verification_options.php.
return;

// Domains that must decode HTML as windows-1251
$kb_windows_1251_domains = [
    'www.imemo.ru',
    'imemo.ru',
    'reg-rt.ru'
];

// Extra KillBot server added to kb_read_servers_from_checked_file.
// {domain} is replaced with the current site host (HTTP_HOST / install domain).
// Examples:
//   '{domain}/'       -> https://example.com
//   '{domain}/path'   -> https://example.com/path
//   '/'               -> current origin (path only)
$kb_extra_server = '{domain}/';
$kb_extra_server_used = false;

// Last-resort KillBot server. Used only if every other server in the list
// failed to answer (ping / fetch timeout).
$kb_reserved_server = 'https://data.killbot.ru';

// Hide "KillBot Free" on the spinner when the subscription expired.
// true = show the label (default). false = do not write it on the page.
$kb_show_free_label = true;

// Show KillBot errors on the verification spinner (long wait / JS errors).
$kb_display_errors = false;

// Page titles, description and preview image (messengers read HTML meta, browsers
// then replace the title via JS). Placeholders: {ip} {user_agent} {domain}
// $kb_page_host is the current site host (HTTP_HOST), already lowercased.
$kb_page_title = 'KillBot user verification [{ip}] [{user_agent}]...';
$kb_page_title_js = 'Проверка пользователя...';
$kb_page_title_js_en = 'User verification...';
$kb_page_title_js_zh = '用户验证中...';
$kb_page_description = '';
// Messenger preview image. Empty = no <meta og:image>. Relative path is turned
// into https://{domain}/.... For the image to show, add this same path to
// KillBot allowed paths (otherwise KillBot blocks the image request as a bot).
$kb_page_image = '';

// Data processing policy link and anchor text (ru / en / zh).
// Placeholders: {ip} {user_agent} {domain}
// Relative path (/policy) or host/path ({domain}/policy) becomes https://...
$kb_privacy_url = 'https://killbot.ru/data_privacy';
$kb_privacy_url_en = 'https://my.kill-bot.net/data_privacy';
$kb_privacy_url_zh = 'https://my.kill-bot.net/data_privacy';
$kb_privacy_text = 'KillBot · Политика обработки технических данных';
$kb_privacy_text_en = 'KillBot · Technical Data Processing Policy';
$kb_privacy_text_zh = 'KillBot · 技术数据处理政策';

// Example: own messenger preview for domain.ru / *.domain.ru (no JS, they keep HTML title).
// Copy the if-block for each extra domain and put your own title/description/image there.
// Empty description or image = that meta tag is not written.
if (!empty($kb_page_host) && ($kb_page_host === 'domain.ru' || substr($kb_page_host, -strlen('.domain.ru')) === '.domain.ru')) {
    $kb_page_title = 'This is the site title for messenger preview on {domain} [{ip}] [{user_agent}]';
    $kb_page_title_js = 'This is the browser JS title for {domain}';
    $kb_page_title_js_en = 'This is the browser JS title for {domain}';
    $kb_page_title_js_zh = 'This is the browser JS title for {domain}';
    $kb_page_description = 'This is the description for messenger preview on {domain}';
    $kb_page_image = '/preview.jpg';
    $kb_privacy_url = 'https://{domain}/data_privacy';
    $kb_privacy_url_en = 'https://{domain}/data_privacy';
    $kb_privacy_url_zh = 'https://{domain}/data_privacy';
    $kb_privacy_text = 'KillBot · Политика обработки технических данных';
    $kb_privacy_text_en = 'KillBot · Technical Data Processing Policy';
    $kb_privacy_text_zh = 'KillBot · 技术数据处理政策';
}

// if (!empty($kb_page_host) && ($kb_page_host === 'shop.com' || substr($kb_page_host, -strlen('.shop.com')) === '.shop.com')) {
//     $kb_page_title = 'This is the site title for messenger preview on {domain} [{ip}] [{user_agent}]';
//     $kb_page_title_js = 'This is the browser JS title for {domain}';
//     $kb_page_description = 'This is the description for messenger preview on {domain}';
//     $kb_page_image = '/preview.jpg';
// }

// Persist kbUserID, kbRes, kbLoaded, kbT cookies. Set false to skip them.
$kb_save_result_cookies = true;

// Shared Yandex Metrika counter for bot visits only (counter id + snapshot 999999).
// All sites connected to this server send bot hits here. Set used to false to disable.
$kb_own_metrika_used = true;
$kb_own_metrika = 110994261;

// Captcha type: 'straight' (align on a line) or 'curve' (align on a sine)
//$captcha_type = 'straight';
$captcha_type = 'curve';

$captcha_logo_data_uri = "url('data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMzQiIGhlaWdodD0iMzQiIHZpZXdCb3g9IjAgMCAzNCAzNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZD0iTTIwLjUwNzEgMTUuMzU3MUMyMC4xMTY2IDE0Ljk2NjYgMTkuNDgzNCAxNC45NjY2IDE5LjA5MjkgMTUuMzU3MUwxOC4xMDY1IDE2LjM0MzVDMTcuNzE2IDE2LjczNCAxNy43MTYgMTcuMzY3MiAxOC4xMDY1IDE3Ljc1NzdMMTkuMDkyOSAxOC43NDQxQzE5LjQ4MzQgMTkuMTM0NiAyMC4xMTY2IDE5LjEzNDYgMjAuNTA3MSAxOC43NDQxTDIxLjQ5MzUgMTcuNzU3N0MyMS44ODQgMTcuMzY3MiAyMS44ODQgMTYuNzM0IDIxLjQ5MzUgMTYuMzQzNUwyMC41MDcxIDE1LjM1NzFaIiBmaWxsPSJ3aGl0ZSIvPgo8cGF0aCBmaWxsLXJ1bGU9ImV2ZW5vZGQiIGNsaXAtcnVsZT0iZXZlbm9kZCIgZD0iTTExLjMwMTIgOS42MDAxNEMxMS4zMDEyIDkuMjY4NjkgMTEuNTY5OSA5IDExLjkwMTMgOUgxOS45OTMyQzIwLjE4NjEgOSAyMC4zNTA5IDkuMDg4MzQgMjAuNDU4OCA5LjIyMTQ2QzIwLjUyMTggOS4yNjM5MSAyMC41ODE1IDkuMzEyOTQgMjAuNjM3MiA5LjM2ODYyTDI3LjQyNyAxNi4xNTg1QzI3Ljg5NTggMTYuNjI3MiAyNy44OTU4IDE3LjM4NzIgMjcuNDI3IDE3Ljg1NTlMMjAuNjM3MiAyNC42NDU4QzIwLjU3MTggMjQuNzExMiAyMC41MDA3IDI0Ljc2NzUgMjAuNDI1NSAyNC44MTQ3QzIwLjMxODIgMjQuOTI3NCAyMC4xNjY1IDI1IDE5Ljk5MTYgMjVIMTAuNzAxQzEwLjM2OTYgMjUgMTAuMTAwOSAyNC43MzEzIDEwLjEwMDkgMjQuMzk5OVYyMi44MTMxQzEwLjEwMDkgMjIuNDgxNyAxMC4zNjk2IDIyLjIxMyAxMC43MDEgMjIuMjEzSDE0LjExMDVDMTQuNTI5NCAyMi4yMTMgMTQuODY4MiAyMS44NzE5IDE0Ljg2NTQgMjEuNDUzQzE0Ljg2MjIgMjAuOTg3NyAxNC40MzcxIDIwLjU3MDQgMTMuOTcxOCAyMC41NzJDMTMuNTQ0NCAyMC41NzM0IDEzLjExOTYgMjAuNTc0MiAxMy4xMDE2IDIwLjU3NDJINy4xMDAxNEM2Ljc2ODcgMjAuNTc0MiA2LjUgMjAuMzA1NSA2LjUgMTkuOTc0VjE4LjUwOTJDNi41IDE4LjE3NzcgNi43Njg3IDE3LjkwOSA3LjEwMDE0IDE3LjkwOUgxMC43Nzg4QzExLjQzMjcgMTcuOTA5IDEyLjA4NjUgMTcuOTA5IDEyLjA4NjUgMTYuOTE0OUMxMi4wODY1IDE1Ljk3MjIgMTEuNDk4NSAxNS45NzQ5IDEwLjg4MDIgMTUuOTc3N0MxMC44NDY1IDE1Ljk3NzggMTAuODEyNiAxNS45NzggMTAuNzc4OCAxNS45NzhIOC4zMDA0M0M3Ljk2ODk5IDE1Ljk3OCA3LjcwMDI5IDE1LjcwOTMgNy43MDAyOSAxNS4zNzc4VjE0LjAzOEM3LjcwMDI5IDEzLjcwNjUgNy45Njg5OSAxMy40Mzc4IDguMzAwNDMgMTMuNDM3OEgxNC4wNTE1QzE0LjUwMzggMTMuNDM3OCAxNC44NzA1IDEzLjA3MTIgMTQuODcwNSAxMi42MTg4QzE0Ljg3MDUgMTIuMTY2NSAxNC41MDM4IDExLjc5OTggMTQuMDUxNSAxMS43OTk4SDExLjkwMTNDMTEuNTY5OSA5IDExLjMwMTIgOS4yNjg2OSAxMS4zMDEyIDkuNjAwMTRaTTE5LjI3OTIgMTEuOTk5OEMxOS41NjA1IDExLjcxODYgMjAuMDE2NCAxMS43MTg2IDIwLjI5NzcgMTEuOTk5OEwyNC43OTYgMTYuNDk4MUMyNS4wNzcyIDE2Ljc3OTQgMjUuMDc3MiAxNy4yMzUzIDI0Ljc5NiAxNy41MTY2TDIwLjI5NzcgMjIuMDE0OUMyMC4wMTY0IDIyLjI5NjEgMTkuNTYwNSAyMi4yOTYxIDE5LjI3OTIgMjIuMDE0OUwxNC43ODA5IDE3LjUxNjZDMTQuNDk5NyAxNy4yMzUzIDE0LjQ5OTcgMTYuNzc5NCAxNC43ODA5IDE2LjQ5ODFMMTkuMjc5MiAxMS45OTk4WiIgZmlsbD0id2hpdGUiLz4KPC9zdmc+Cg==')";

$curve_overlay_bg            = '#fff';
$curve_text_above            = '"+kbGetVerificationText("capt_curve")+"';
$curve_text_max_width        = '420px';
$curve_text_font             = '500 18px/1.4 system-ui,-apple-system,Segoe UI,sans-serif';
$curve_text_color            = '#4b5563';
$curve_text_letter_spacing   = '.1px';

// Captcha design: align on a straight line
$straight_bg_color                = '#f0f0f0';
$straight_overlay_bg              = '#fff';

$new_bg_color                = $straight_bg_color;
$new_overlay_bg              = $straight_overlay_bg;

//$straight_text_above         = 'Текст над \\\\A капчей';
$new_text_above              = '"+kbGetVerificationText("capt_straight")+"';
$new_text_max_width          = '340px';
$new_text_margin_bottom      = '40px';
$new_text_font               = '500 18px/1.4 system-ui,-apple-system,Segoe UI,sans-serif';
$new_text_color              = '#4b5563';
$new_text_letter_spacing     = '.1px';

$new_scene_width             = '300px';
$new_scene_height            = '80px';

$new_path_left               = '66px';
$new_path_right              = '76px';
$new_path_color              = 'rgba(42,94,246,0.55)';

$new_arrow_right             = '70px';
$new_arrow_size              = '12px';
$new_arrow_color             = 'rgba(42,94,246,0.8)';

$new_slot_size               = '60px';
$new_slot_border             = '2px dashed rgba(42,94,246,0.55)';
$new_slot_bg                 = 'rgba(42,94,246,0.06)';
$new_slot_logo_bg            = 'rgba(42,94,246,0.35)';

$new_pulse_shadow_1          = '0 0 0 6px rgba(42,94,246,0.10),0 0 0 12px rgba(42,94,246,0.04)';
$new_pulse_shadow_2          = '0 0 0 10px rgba(42,94,246,0.14),0 0 0 20px rgba(42,94,246,0.03)';

$new_piece_size              = '60px';
$new_piece_bg                = 'linear-gradient(145deg,#4F7DFF,#2A5EF6 55%,#1A42CC)';
$new_piece_shadow            = '0 14px 28px -6px rgba(42,94,246,0.55),0 0 0 1px rgba(42,94,246,0.35),inset 0 1px 0 rgba(255,255,255,0.35)';
$new_piece_hover_shadow      = '0 14px 28px -6px rgba(42,94,246,0.55),0 0 0 1px rgba(42,94,246,0.35),inset 0 1px 0 rgba(255,255,255,0.35),0 0 0 8px rgba(42,94,246,0.08)';

$new_fake_path_color         = 'rgba(42,94,246,0.22)';
$new_fake_arrow_color        = 'rgba(42,94,246,0.28)';
$new_fake_slot_border        = '2px dashed rgba(42,94,246,0.24)';
$new_fake_slot_bg            = 'rgba(42,94,246,0.02)';
$new_fake_slot_logo_bg       = 'rgba(42,94,246,0.14)';
$new_fake_piece_bg           = 'linear-gradient(145deg,rgba(79,125,255,0.25),rgba(42,94,246,0.18) 55%,rgba(26,66,204,0.18))';
$new_fake_piece_shadow       = '0 10px 20px -8px rgba(42,94,246,0.15),0 0 0 1px rgba(42,94,246,0.12),inset 0 1px 0 rgba(255,255,255,0.12)';
$new_fake_piece_logo_opacity = '0.22';
