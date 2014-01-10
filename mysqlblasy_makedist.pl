#!/usr/bin/perl

print "Make sure to have a clean checkout from the repository!\n";

my $version = shift @ARGV;
unless (defined $version || length($version) > 0 ) {
	die "Give version number on command line!";
};
print "Using version $version\n";
die "Die mysqlblasy-$version/ already exists.\n" if (-d "mysqlblasy-$version/");

print `rm -rf dist/mysqlblasy-$version`;
print `mkdir -p dist/mysqlblasy-$version`;
print `cp CHANGES dist/mysqlblasy-$version/`;
print `cp *.sample dist/mysqlblasy-$version/`;
print `cp LICENSE dist/mysqlblasy-$version/`;
print `cp mysqlblasy.pl dist/mysqlblasy-$version/`;
print `cp README dist/mysqlblasy-$version/`;
print `cp TODO dist/mysqlblasy-$version/`;
print `chmod 755 dist/mysqlblasy-$version/mysqlblasy.pl`;

print `cd dist && pod2html --noindex mysqlblasy-$version/mysqlblasy.pl > mysqlblasy-$version/mysqlblasy.pod.html`;

print `cd dist && tar cvzf mysqlblasy-$version.tgz mysqlblasy-$version/`;

print "Tarball is: mysqlblasy-$version.tgz\n";
