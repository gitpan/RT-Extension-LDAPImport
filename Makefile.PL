use inc::Module::Install;

name ('RT-Extension-LDAPImport');
author ('Kevin Falcone <falcone@bestpractical.com>');
license('perl');
all_from('lib/RT/Extension/LDAPImport.pm');

requires('Test::More');
requires('Net::LDAP');
requires('RT' => '3.6.3');
requires('Class::Accessor');

&WriteAll;
