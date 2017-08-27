#!/usr/bin/env perl

use strict;
use warnings;

use File::Find;

if (! -d 'lib') {
    exit(1);
}

my $exceptions = {
    'skeleton.oauth.lua' => 1,
    'skeleton.plain.lua' => 1,
};

my $modules = {};

find( sub {
    if(-d $_) {
        return;
    }

    if(exists($exceptions->{$_})) {
        return;
    }

    my $filename = $File::Find::dir . '/' . $_;
    my $modname = $filename;

    $modname =~ s,^lib/,,;
    $modname =~ s,\.(et)?lua$,,;
    $modname =~ s,/,.,g;

    $modules->{$modname} = $filename;

    #print "      [\"$modname\"] = \"$filename\",\n";

}, 'lib');

my @modnames = sort { $a cmp $b } keys %$modules;

foreach my $modname (@modnames) {
    printf "      [\"%s\"] = \"%s\",\n", $modname, $modules->{$modname};
}
