<?php
// Local KillBot server settings.
// Created once at /opt/killbot/settings.php and not overwritten on update.
// Edit this file as root. www-data can read it but cannot change it.

// Accept fullchain + privkey from the centralized LE server (le_receive_cert.php).
// Set to false to refuse every POST, never write keys, and never delete local certbot certs.
$kb_accept_centralized_certs = true;

// Allow /opt/killbot/install.sh to configure or reconfigure sites (including via kb.php).
// Set to false so install.sh exits immediately and does not change site config.
$kb_allow_install_sh = true;

// IPs allowed to POST certificates to le_receive_cert.php
$kb_le_allowed_server_ips = ['45.66.116.213', '31.211.65.236'];

$kb_le_ssl_base_dir = '/opt/killbot/ssl';
$kb_le_letsencrypt_dir = '/etc/letsencrypt';

// After a successful centralized receive, delete the local certbot certificate for that domain.
// Ignored when $kb_accept_centralized_certs is false.
$kb_le_remove_local_letsencrypt = true;
