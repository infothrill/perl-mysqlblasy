#!/usr/bin/perl

print "Make sure to have a clean checkout from the repository!\n";

my $version = shift @ARGV;
unless (defined $version || length($version) > 0 ) {
	die "Give version number on command line!";
};
print "Using version $version\n";
die "Die mysqlblasy-$version/ already exists.\n" if (-d "mysqlblasy-$version/");

print `cp -ax mysqlblasy mysqlblasy-$version`;

print `rm -rf mysqlblasy-$version/.svn/`;
print `rm -rf mysqlblasy-$version/.cvsignore`;
print `rm -rf mysqlblasy-$version/ChangeLog`;
print `rm -rf mysqlblasy-$version/*~`;
print `rm -rf mysqlblasy-$version/*.bak`;
print `chmod 755 mysqlblasy-$version/mysqlblasy.pl`;
print `pod2html --noindex mysqlblasy-$version/mysqlblasy.pl > mysqlblasy-$version/mysqlblasy.pod.html`;

print `tar cvzf mysqlblasy-$version.tgz mysqlblasy-$version/`;
print `rm -rf mysqlblasy-$version/`;

print "Tarball is: mysqlblasy-$version.tgz\n";
