<?php
/**
 * Hearthost phpMyAdmin config. Cookie auth against MariaDB on loopback.
 * Tenants only see databases MySQL grants allow (user_%).
 */
declare(strict_types=1);

$cfg['blowfish_secret'] = '{{BLOWFISH}}';

$i = 0;
$i++;
$cfg['Servers'][$i]['auth_type'] = 'cookie';
$cfg['Servers'][$i]['host'] = '127.0.0.1';
$cfg['Servers'][$i]['compress'] = false;
$cfg['Servers'][$i]['AllowNoPassword'] = false;
$cfg['Servers'][$i]['hide_db'] = '^(information_schema|performance_schema|mysql|sys)$';

$cfg['ForceSSL'] = true;
$cfg['AuthLog'] = 'syslog';
$cfg['LoginCookieValidity'] = 3600;
$cfg['PmaAbsoluteUri'] = 'https://{{PMA_HOST}}/';
$cfg['CheckConfigurationPermissions'] = false;
$cfg['VersionCheck'] = false;
$cfg['AllowArbitraryServer'] = false;
$cfg['UploadDir'] = '';
$cfg['SaveDir'] = '';
$cfg['TempDir'] = '{{PMA_HOME}}/tmp';
$cfg['PmaNoRelation_DisableWarning'] = true;
