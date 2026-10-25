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
$cfg['Servers'][$i]['host'] = 'localhost';
$cfg['Servers'][$i]['socket'] = '';
$cfg['Servers'][$i]['compress'] = false;
$cfg['Servers'][$i]['AllowNoPassword'] = false;
$cfg['Servers'][$i]['hide_db'] = '^(information_schema|performance_schema|mysql|sys)$';

/* Configuration storage (extended features, bookmarks, tracking, etc.) */
$cfg['Servers'][$i]['controluser'] = '{{PMA_CONTROL_USER}}';
$cfg['Servers'][$i]['controlpass'] = '{{PMA_CONTROL_PASS}}';
$cfg['Servers'][$i]['pmadb'] = 'phpmyadmin';
$cfg['Servers'][$i]['bookmarktable'] = 'pma__bookmark';
$cfg['Servers'][$i]['relation'] = 'pma__relation';
$cfg['Servers'][$i]['table_info'] = 'pma__table_info';
$cfg['Servers'][$i]['table_coords'] = 'pma__table_coords';
$cfg['Servers'][$i]['pdf_pages'] = 'pma__pdf_pages';
$cfg['Servers'][$i]['column_info'] = 'pma__column_info';
$cfg['Servers'][$i]['history'] = 'pma__history';
$cfg['Servers'][$i]['table_uiprefs'] = 'pma__table_uiprefs';
$cfg['Servers'][$i]['tracking'] = 'pma__tracking';
$cfg['Servers'][$i]['userconfig'] = 'pma__userconfig';
$cfg['Servers'][$i]['recent'] = 'pma__recent';
$cfg['Servers'][$i]['favorite'] = 'pma__favorite';
$cfg['Servers'][$i]['users'] = 'pma__users';
$cfg['Servers'][$i]['usergroups'] = 'pma__usergroups';
$cfg['Servers'][$i]['navigationhiding'] = 'pma__navigationhiding';
$cfg['Servers'][$i]['savedsearches'] = 'pma__savedsearches';
$cfg['Servers'][$i]['central_columns'] = 'pma__central_columns';
$cfg['Servers'][$i]['designer_settings'] = 'pma__designer_settings';
$cfg['Servers'][$i]['export_templates'] = 'pma__export_templates';

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
