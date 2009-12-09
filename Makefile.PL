use inc::Module::Install;
use strict;

name 'WWW-Scraper-Flickr';
all_from 'lib/WWW/Scraper/Flickr.pm';

install_script 'flickr';
install_script 'flickr-gtk';

WriteAll;
