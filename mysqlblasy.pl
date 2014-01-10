#!/usr/bin/perl
############################################################
# POD Header
############################################################

=head1 NAME

mysqlblasy - MySQL backup for lazy sysadmins

=head1 SYNOPSIS

B<mysqlblasy> [OPTIONS]

=head1 DESCRIPTION

B<mysqlblasy> is a Perl script for automating MySQL database backups. It uses
`mysqldump` for dumping mysql databases to the filessytem. It was written with
automated usage in mind, e.g. it is very silent during operation and only
produces noise on errors/problems. It rotates backups automatically to avoid
that the backup disk gets full when the administrator is on vacation (or is
lazy). All necessary information for producing backups can be specified in a
configuration file, which eliminates the need to hide command line options from
the process table (like passwords).

Each database gets dumped into a separate file, after which all the dumps get
tarred/compressed and placed into the specified backup
directory. Old files in the backup directory get deleted, and the number
you specify newest files are kept (default 7).

Backups get filenames containing the hostname, the date and the time (accuracy:
seconds).

Optionally, after the dumping has completed, mysqlblasy can run 'OPTIMIZE TABLE'
on each table in the backup set.

The verbosity of the output can be specified using the B<loglevel> configuration
key. The recommended value for the loglevel is 2 (WARN).

=head1 CONFIGURATION FILE(S)

Configuration files: /etc/mysqlblasy.conf, $HOME/.mysqlblasyrc

Allowed config keys and values:

   backupdir           = directory for placing the backup
   databases           = comma separated list of db's to backup (default all)
   exclude databases   = comma separated list of db's to NOT backup
   defaults-extra-file = path to an alternative my.cnf config file
   dbusername          = mysql username (it is recommended  to use defaults-extra-file)
   dbpassword          = password for user (it is recommended  to use defaults-extra-file)
   dbhost              = hostname of database server, this is used for the backup filename too.
                         If you use a defaults-extra-file, this can be used to set the filename
                         of the backup-file!
   optimize_tables     = yes or no or 1 or 0 (default no)
   loglevel            = NOP(0) ERR(1) WARNING(2) NOTICE(3) INFO(4) DEBUG(5), default 2
   mysql               = absolute path to the mysql binary (default from $PATH)
   mysqldump           = absolute path to the mysqldump binary (default from $PATH)
   use compression     = yes or no or 1 or 0 (default no)
   compression tool    = see below
   keep                = number of backup files to keep in backupdir
   use syslog          = yes or no or 1 or 0 (default yes)
   tar                 = see below

Some of these configuration values may require special attention:
'compression tool' and 'tar' can be specified with their absolute filenames or
with only the basename of the executable. If the the specified value cannot be
resolved, mysqlblasy does NOT fall back to a default tool!

All configuration keys consisting of a filename/path can have a tilde '~'
for specifying these HOME directory of the user running mysqlblasy.

Concerning security and mysql password disclosure in the process
table, the recommended way to either use the mysql built-in config file 
called ~/.my.cnf and leave out the username and password or to specify
an alternative config file with the defaults-extra-file option.

Example:

   [client]
   host     = localhost
   user     = bob
   password = y0uRp4s5w0r6
   socket   = /var/run/mysqld/mysqld.sock

=head1 OPTIONS

=over 4

=item B<-c, --config-file> file

Specify an alternative config file. The system-wide configuration is still read,
but settings in the specified config file will override the system-wide ones.

=item B<-h, --help>

Displays this help

=item B<-V, --version>

Display version and exit

=back

=head1 NOTES

B<mysqlblasy> will try to use native command line utilities for tarring and
compressing. If no adequate tools are found, it will try to use Perl native
routines for tarring and compressing (requires some modules to be installed).
The command lines tools are preferred for perfomance reasons (especially
memory usage).

=head1 LICENSE

This program is distributed under the terms of the BSD Artistic License.

=head1 AUTHOR

Copyright (c) 2003-2008 Paul Kremer.

=head1 BUGS

Please send patches in unified GNU diff format to <pkremer[at]spurious[dot]biz>

=head1 SEE ALSO

mysql, mysqldump, Sys::Syslog, tar, gzip, bzip2, Archive::Tar, Achive::Zip

=cut

use 5.006001;
use strict;
use warnings;
use File::Basename;    # should be in Perl base install
use File::Spec;        # should be in Perl base install

use vars qw($Me $_cwd $_workDir $_hostDir $_globalCfg $_glb);

=head1 Function documentation

=over

=item bootinit()

bootinit() will initialize some variables as well as environmental variables and load the required perl modules.

=cut

sub bootinit
{
	$_globalCfg = undef;    # holds the global config keys and values
	$_glb       = undef;    # holds global variables
	$Me = File::Basename::basename($0);          # basename of this program
	delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};    # security!!
	$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};    # security!!
	$| = 1;                                           # autoflush output
	setConfigValue( 'loglevel', 2 );        # loglevel warn by default
	setConfigValue( 'syslog',   undef );    # don't try syslog during bootstrap
	$_workDir     = undef;                  # init
	$_hostDir     = undef;                  # init
	$_glb->{Name} =
	  'mysqlblasy';    # what are we called? (used for config filenames)
	                   # load perl modules:
	my @_use = (
		'File::Find qw(finddepth)', 'Getopt::Long;',
		'Data::Dumper',             'POSIX qw(strftime)',
		'Cwd',                      'Sys::Hostname'
	);

	foreach my $u (@_use)
	{
		if ( my $e = &try_to_use($u) )
		{
			graceful_die($e);
		}
	}
	$_cwd = Cwd::getcwd();    # remember dir we started in
}

=item cfginit()

cfginit() will initialize the configuration, depending on command line parameters.

=cut

sub cfginit
{
	my $cfghash = undef;
	if ( defined $_glb->{opts}->{cfg} )
	{
		$cfghash = getPreferences( $_glb->{opts}->{cfg} );
	}
	else
	{
		$cfghash = getPreferences();
	}

	# merge the current cfg with the cfg just read (and override current cfg!):
	%$_globalCfg = ( %$_globalCfg, %$cfghash );

	# check for syslog:

	if ( $^O !~ /MSWin32/ && defined getConfigValue('syslog') )
	{
		if ( my $e = &try_to_use('Sys::Syslog qw(:DEFAULT setlogsock)') )
		{
			setConfigValue( 'syslog', undef );    # don't use syslog
			logWarn(
				'Will not use syslog, because the module is not installed:',
				$e );
		}
	}
	logDebug($_globalCfg);
	return 1;
}

=item try_to_use(use_string)

will eval "use use_string" and return undef if it worked. Otherwise returns the exception text.

=cut

sub try_to_use
{
	my $u = shift;
	eval "use $u";
	if ( my $e = $@ )
	{
		return "Module $u not installed: $e";
	}
	else
	{
		return undef;
	}
}

=item graceful_die(string message)

graceful_die() will log the given message as error and die.

=cut

sub graceful_die
{
	my $msg = shift;
	unless ( defined $msg && $msg ne '' )
	{
		$msg = '';
	}
	_logIt( 1, $msg );
	$msg = _logString($msg);
	if ( defined $_cwd && -d $_cwd )
	{
		chdir $_cwd;
	}
	cleanup();
	die $msg;
	return undef;
}

# to be called on die and on successfull finish:
sub cleanup
{
	if ( defined $_cwd && -d $_cwd )
	{
		chdir $_cwd;
	}
	my $dir = workDir();
	if ( my $e = &try_to_use("File::Path") )
	{
		logDebug(
"File::Path unavailable, using built-in recursive directory deletion (this is UNSUPPORTED)"
		);
		File::Find::finddepth( \&zap, $dir );
		rmdir $dir;
	}
	else
	{
		my $result = File::Path::rmtree( [$dir], 0, 1 );
		logDebug( "File::Path recursive deletion returned",
			$result, "deleted files" );
	}
	logInfo( "Removed all temp files in", $dir );
	return 1;
}

sub zap
{
	if ( !-l && -d _ )
	{
		logDebug("rmdir $File::Find::name");
		rmdir($File::Find::name)
		  or logErr("couldn't rmdir $File::Find::name: $!");
	}
	else
	{
		logDebug("unlink $File::Find::name");
		unlink($File::Find::name)
		  or logErr("couldn't unlink $File::Find::name: $!");
	}
}

=item _logString(mixed message)

_logString() will add debugging information to message and return it. If message
is not a string, the variable will be preprocessed by Data::Dumper::Dumper().

=cut

sub _logString
{
	my $msg = shift;

	$msg = 'undef' unless defined $msg;  # avoid concatenation of undefined vars

	if ( ref($msg) )
	{
		$msg = Data::Dumper::Dumper($msg);
	}
	my $level = 2;                       # default nesting for the log* methods

	my @callerinfo = caller($level);
	my $line       = $callerinfo[2];
	@callerinfo = caller( $level + 1 );
	my $routine = $callerinfo[3];

	unless ( defined $routine )
	{
		$level      = 1;                 # default nesting for the log* methods
		@callerinfo = caller($level);
		$line       = $callerinfo[2];
		@callerinfo = caller( $level + 1 );
		$routine    = $callerinfo[3];
	}
	unless ( defined $routine )
	{
		$level = 0;                      # default nesting for the log* methods
		@callerinfo = caller( $level + 1 );
		$routine    = $callerinfo[3];
	}
	unless ( defined $routine )
	{
		$routine = 'unkown routine';
	}
	unless ( defined $line )
	{
		$line = 'unknown';
	}
	my $string = $routine . ' line ' . $line . ': ' . $msg;
}

=item _logIt(mixed message, int atlevel)

will format and log the message if atlevel is smaller or equal than the
configured loglevel. Returns the logged message if it got logged to the
logging backend.

=cut

sub _logIt
{
	my $atlevel = shift;
	my @items   = @_;
	push @items, '(no data, no text)' unless @items;
	foreach my $item (@items)
	{
		if ( ref($item) )
		{
			$item = Data::Dumper::Dumper($item);
		}
		elsif ( not defined $item )
		{
			$item = '(undef)';
		}
	}
	my $msg = join( ' ', @items );

	$msg = 'undef' unless defined $msg;  # avoid concatenation of undefined vars

	my @debuglevelstr = qw(nop err warning notice info debug);
	if ( getConfigValue('loglevel') >= $atlevel )
	{
		my $str = $debuglevelstr[$atlevel] . ' ' . _logString($msg);
		$str =~ s/\n//g;
		$str =~ s/\r//g;                 # no line breaks in log messages!
		unless ( $str =~ /^.*\n$/ )
		{
			$str .= "\n";
		}
		_logToConsole($str);
		_logToSyslog( $str, $atlevel );
		return $str;
	}
	else
	{
		return undef;
	}
}

=item log*(mixed message)

log*() will log the message at the corresponding LOGLEVEL and return the
logged message, if it was logged.

=cut

sub logErr    { my @msg = @_; return _logIt( 1, @msg ); }
sub logWarn   { my @msg = @_; return _logIt( 2, @msg ); }
sub logNotice { my @msg = @_; return _logIt( 3, @msg ); }
sub logInfo   { my @msg = @_; return _logIt( 4, @msg ); }
sub logDebug  { my @msg = @_; return _logIt( 5, @msg ); }

=item _logToConsole(string message)

_logToConsole() will send message to the console (STDERR). Always returns 1.

=cut

sub _logToConsole
{
	my $msg     = shift;
	print STDERR $msg;
	return 1
}

=item _logToSyslog(string message, int atlevel)

_logToSyslog() will send message to the system syslog facility at the specified
level. Always returns 1.

=cut

sub _logToSyslog
{
	my $msg     = shift;
	my $atlevel = shift;

	if ( getConfigValue('syslog') )
	{
		$msg = 'undef'
		  unless defined $msg;    # avoid concatenation of undefined vars
		my @debuglevel = qw(nop err warning notice info debug);

		#my @socktypes = qw (unix inet tcp udp stream);
		setlogsock('unix');       # we use local unix socket
		openlog( $Me, 'cons,pid,nowait' );
		syslog( $debuglevel[$atlevel], $msg );
		closelog();
	}
	return 1;
}

=item getConfigValue(string key)

getConfigValue() returns a string for the given configuration key. It fails on
error. Note that this function uses the global config container, which means
that configuration needs to be initialized before using this method.

=cut

sub getConfigValue
{
	my $key = shift;
	if ( not defined $key or $key eq '' )
	{
		graceful_die "No key given in getConfigValue()";
	}

	if ( !defined $_globalCfg->{$key} )
	{
		return undef;
	}
	return $_globalCfg->{$key};
}

=item setConfigValue(string key, value)

setConfigValue() sets the value for the given configuration key. It fails on
error.

=cut

sub setConfigValue
{
	my $key   = shift;
	my $value = shift;
	if ( not defined $key or $key eq '' )
	{
		graceful_die "No key given in setConfigValue()";
	}

	if ( defined $_globalCfg->{$key} )
	{
		logNotice(
			"Overwriting cfg key (",          $key,
			") given in setConfigValue() to", $value
		);
	}
	$_globalCfg->{$key} = $value;
}

=item ldb_databases()

ldb_databases() will return a list of databases on the mysql
server. It fails on error.

=cut

sub ldb_databases
{
	my @cmd = ( getConfigValue('mysql') );

	# if a defaults-extra-file was specified, use it!
	if ( my $defaultsextrafile = getConfigValue('defaultsextrafile') )
	{
			push( @cmd, "--defaults-extra-file=$defaultsextrafile" );
	}
	else # otherwise, rely on direct username/password/host from cfg:
	{
		if ( my $u = getConfigValue('dbusername') )
		# no user, use current ENV user (mysqldump does that!)
		{
			push( @cmd, '--user' );
			push( @cmd, $u );
		}
		if ( my $p = getConfigValue('dbpassword') )
		{
			push( @cmd, "--password=$p" );
		}
		if ( my $h = getConfigValue('dbhost') )
		{
			push( @cmd, '--host' );
			push( @cmd, $h );
		}
	}
	push( @cmd, '--silent' );
	push( @cmd, '--exec', 'SHOW DATABASES' );
	logDebug(@cmd);

	my $output        = '';
	my $output_target = mkstempt();
	if ( my $result = _system( \@cmd, $output_target ) )
	{
		logInfo("Successfully saved to $output_target");
		fuFile( $output_target, \$output );
	}
	else
	{
		# get the command line in a string and hide password:
		my $cmdstr = join( ' ', @cmd );
		if ( my $p = getConfigValue('dbpassword') )
		{
			$cmdstr =~ s/$p/xxxxxx/;
		}

		# log it:
		logErr( 'Command failed: ', $cmdstr );
		logErr('An error occured while fetching the list of databases');
		
		my $result = undef;
		eval { $result = fuFile( $output_target, \$output ); };
		if ( my $e = $@ )
		{    # exception!
			die 'fuFile threw an exception: ' . $e;
		}
		elsif ( !$result )
		{
			die "fuFile could not read data from $output_target";
		}
		graceful_die("Could not fetch the list of databases!");
		return undef;
	}
	my @l = split( /\n/, $output );
	logDebug(@l);
	return @l;
}

=item ldb_database_tables()

ldb_database_tables() will return a list of tables in the given database on the
mysql server. It fails on error.

=cut

sub ldb_database_tables
{
	my $database = shift || graceful_die("Need parameter 'database'");
	my @cmd = ( getConfigValue('mysql') );

	# if a defaults-extra-file was specified, use it!
	if ( my $defaultsextrafile = getConfigValue('defaultsextrafile') )
	{
			push( @cmd, "--defaults-extra-file=$defaultsextrafile" );
	}
	else # otherwise, rely on direct username/password/host from cfg:
	{
		if ( my $u = getConfigValue('dbusername') )
		# no user, use current ENV user (mysqldump does that!)
		{
			push( @cmd, '--user' );
			push( @cmd, $u );
		}
		if ( my $p = getConfigValue('dbpassword') )
		{
			push( @cmd, "--password=$p" );
		}
		if ( my $h = getConfigValue('dbhost') )
		{
			push( @cmd, '--host' );
			push( @cmd, $h );
		}
	}
	# add the database name:
	push(@cmd, '-D', $database);

	push( @cmd, '--exec', 'SHOW TABLES' );
	logDebug(@cmd);

	my $output        = '';
	my $output_target = mkstempt();
	if ( my $result = _system( \@cmd, $output_target ) )
	{
		fuFile( $output_target, \$output );
	}
	else
	{
		# get the command line in a string and hide password:
		my $cmdstr = join( ' ', @cmd );
		if ( my $p = getConfigValue('dbpassword') )
		{
			$cmdstr =~ s/$p/xxxxxx/;
		}

		# log it:
		logErr( 'Command failed: ', $cmdstr );
		logErr("An error occured while fetching the list of tables in database '$database'");
		
		my $result = undef;
		eval { $result = fuFile( $output_target, \$output ); };
		if ( my $e = $@ )
		{    # exception!
			die 'fuFile threw an exception: ' . $e;
		}
		elsif ( !$result )
		{
			die "fuFile could not read data from $output_target";
		}
		graceful_die("Could not fetch the list of tables!");
		return undef;
	}
	my @l = split( /\n/, $output );
	logDebug(@l);
	shift @l; # remove the line Tables_in_$databasename, it's always the first one.
	return @l;
}

=item ldb_databases()

ldb_databases() will return a list of databases on the mysql
server. It fails on error.

=cut

sub myoptimize
{
	my $database = shift || graceful_die("Need parameter 'database'");
	my $table = shift || graceful_die("Need parameter 'table'");

	my @cmd = ( getConfigValue('mysql') );

	# if a defaults-extra-file was specified, use it!
	if ( my $defaultsextrafile = getConfigValue('defaultsextrafile') )
	{
			push( @cmd, "--defaults-extra-file=$defaultsextrafile" );
	}
	else # otherwise, rely on direct username/password/host from cfg:
	{
		if ( my $u = getConfigValue('dbusername') )
		# no user, use current ENV user (mysqldump does that!)
		{
			push( @cmd, '--user' );
			push( @cmd, $u );
		}
		if ( my $p = getConfigValue('dbpassword') )
		{
			push( @cmd, "--password=$p" );
		}
		if ( my $h = getConfigValue('dbhost') )
		{
			push( @cmd, '--host' );
			push( @cmd, $h );
		}
	}
	# add the database name:
	push(@cmd, '-D', $database);

	push( @cmd, '--exec', "OPTIMIZE TABLE `$table`" );
	logDebug(@cmd);

	my $output        = '';
	my $output_target = mkstempt();
	if ( my $result = _system( \@cmd, $output_target ) )
	{
		fuFile( $output_target, \$output );
	}
	else
	{
		# get the command line in a string and hide password:
		my $cmdstr = join( ' ', @cmd );
		if ( my $p = getConfigValue('dbpassword') )
		{
			$cmdstr =~ s/$p/xxxxxx/;
		}

		# log it:
		logErr( 'Command failed: ', $cmdstr );
		logErr("An error occured while optimizing table '$table' in database '$database'");
		
		my $result = undef;
		eval { $result = fuFile( $output_target, \$output ); };
		if ( my $e = $@ )
		{    # exception!
			die 'fuFile threw an exception: ' . $e;
		}
		elsif ( !$result )
		{
			die "fuFile could not read data from $output_target";
		}
		graceful_die("Could not optmize table!");
		return undef;
	}
	my @l = split( /\n/, $output );
	logDebug(@l);
	return @l;
}


=item _system(arrayref params, string out)

_system is a wrapper for the perl system() function. It handles exit codes
gracefully and can redirect STDOUT and STDERR of the executed program to the
file specified by out. It returns true on success and false on error. It never fails.
By default, STDOUT and STDERR are redirected to the null device, to disable
output redirection, specify the empty string as output target. _system() never
forks a shell (/bin/sh).

=cut

sub _system
{
	my $cmd = shift;    # array ref with system() parameters
	my $out = shift;    # target for stdout

	if ( !ref($cmd) =~ /ARRAY/ )
	{
		graceful_die("Parameter is not an array reference in _system()");
	}
	logDebug($cmd);

	if ( not defined $out )
	{
		$out = File::Spec->devnull();
	}

	# init vars
	my $exitcode    = undef;
	my $exit_value  = undef;
	my $signal_num  = undef;
	my $dumped_core = undef;

	# ATTENTION: any attempt to output something
	# to either STDOUT or STDERR will break things here,
	# so do not LOG anything here until the file descriptors are
	# closed again!
	if ( defined $out && $out ne '' )
	{

		# take copies of the file descriptors
		open( OLDOUT, ">&STDOUT" )
		  || graceful_die("Can't take a copy of STDOUT: $!");
		open( OLDERR, ">&STDERR" )
		  || graceful_die("Can't take a copy of STDERR: $!");

		# redirect stdout and stderr
		open( STDOUT, "> $out" )
		  or graceful_die("Can't redirect stdout to '$out': $!");
		open( STDERR, ">&STDOUT" ) or graceful_die("Can't dup stdout: $!");

		#	open(STDERR, ">&STDOUT") or die "Can't dup stdout: $!";
	}

	# run the program
	if ( my $dummy = system( @{$cmd} ) )
	{
		$exitcode    = $?;
		$exit_value  = $? >> 8;
		$signal_num  = $? & 127;
		$dumped_core = $? & 128;
	}

	if ( defined $out && $out ne '' )
	{

		# close the redirected filehandles
		close(STDOUT) or graceful_die("Can't close STDOUT: $!");
		close(STDERR) or graceful_die("Can't close STDERR: $!");

		# restore stdout and stderr
		open( STDERR, ">&OLDERR" ) or graceful_die("Can't restore stderr: $!");
		open( STDOUT, ">&OLDOUT" ) or graceful_die("Can't restore stdout: $!");

		# avoid leaks by closing the independent copies
		close(OLDOUT) or graceful_die("Can't close OLDOUT: $!");
		close(OLDERR) or graceful_die("Can't close OLDERR: $!");
	}

	if ( defined $exitcode )
	{    # something failed
		logWarn("system(\@cmd) failed: $exitcode")
		  ;    # we don't log the command line as it may contain passwords
		logWarn(
"exit_value: $exit_value signal_num: $signal_num dumped_core: $dumped_core"
		);
		return 0;
	}
	else
	{
		return 1;
	}
}

=item _hostname

_hostname() is a safe wrapper for Sys::Hostname::hostname(). It returns the
hostname on success and the empty string on failure.

=cut

sub _hostname
{
	my $hostname = undef;
	if ( my $h = getConfigValue('dbhost') )
	{
		$hostname = $h;
	}
	else
	{
		eval { $hostname = Sys::Hostname->hostname(); };
		if ( my $e = $@ )
		{    # exception!
			logWarn($e);
		}
		if ( not defined $hostname )
		{
			logWarn('hostname could not be determined');
			$hostname = '';
		}
	}
	return $hostname;
}

=item tmpDir()

tmpDir() will return the system-wide temporary directory name. See
File::Spec->tmpdir() for details.

=cut

sub tmpDir
{
	my $tmpdir = File::Spec->tmpdir();
	if ( $tmpdir eq File::Spec->curdir() )
	{
		logWarn( 'tmpdir fell back to the current directory:', $tmpdir );
	}
	return $tmpdir;
}

=item mkstempt()

mkstempt() will return a temporary file name. The file will have been created by
the time the method returns. This prevents any possibility of opening up an
identical file.

=cut

sub mkstempt
{
	my $tmpdir = tmpDir();

	my $rand = 0;
	while (
		-f File::Spec->catfile( $tmpdir,
			$Me . '-' . $$ . '-' . $rand . '.temp' ) )
	{
		$rand =
		  int( rand 1 * 1000 )
		  ;    # gives us 999 different names, should be enough!
	}
	my $tempname =
	  File::Spec->catfile( $tmpdir, $Me . '-' . $$ . '-' . $rand . '.temp' );
	if ( !-f $tempname )
	{
		my $FILE;
		open( $FILE, ">$tempname" );
		die "autsch" unless defined $FILE;
		chmod 0600,
		  $tempname || graceful_die "Could not chmod '" . $tempname . "'";
	}
	logDebug( 'returning new temporary filename:', $tempname );
	return $tempname;
}

=item workDir()

workDir() will create a temporary directory and return the full path. If the
directory already exists, it will choose a different path. If the directory was
created from within the same process, it simply returns it. It fails on error.

=cut

sub workDir
{
	if ( defined $_workDir && -d $_workDir )
	{
		logDebug( 'returning already existing workdir:', $_workDir );
		return $_workDir;
	}
	my $tmpdir = tmpDir();
	my $prefix = $$ . $_glb->{Name};
	my $rand   = 0;
	while ( -d File::Spec->catdir( $tmpdir, $prefix . $rand ) )
	{
		$rand =
		  int( rand 1 * 1000 )
		  ;    # gives us 999 different names, should be enough!
	}
	my $newworkdir = File::Spec->catdir( $tmpdir, $prefix . $rand );
	if ( !-d $newworkdir )
	{
		mkdir($newworkdir)
		  || graceful_die "Could not create '" . $newworkdir . "'";
		chmod 0700,
		  $newworkdir || graceful_die "Could not chmod '" . $newworkdir . "'";
	}
	$_workDir = $newworkdir;
	logDebug( 'returning new workdir:', $_workDir );
	return $_workDir;
}

=item hostDir()

hostDir() will create a directory inside workDir(). The name of the subdirectory
if based on the 'dbhost' config value, or the local hostname if omitted.
It returns the full path. If the directory was created from
within the same process, it simply returns it. It fails on error.

=cut

sub hostDir
{
	if ( defined $_hostDir && -d $_hostDir )
	{
		logDebug( 'returning already existing hostdir:', $_hostDir );
		return $_hostDir;
	}
	my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
	  localtime time;
	$year += 1900;
	my $d = sprintf( "%04d_%02d_%02d-%02d_%02d_%02d",
		$year, $mon + 1, $mday, $hour, $min, $sec );
	my $dir = File::Spec->catdir( workDir(), _hostname() . '_' . $d );

	mkdir($dir) || graceful_die "Could not create '$dir'";
	chmod 0700, $dir || graceful_die "Could not chmod '$dir'";

	$_hostDir = $dir;
	logDebug( 'returning new hostdir:', $_hostDir );
	return $dir;
}

=item getPath

getPath() will take the environment variable called PATH and parse it into an
ARRAY of which it will return a reference. In case the environment variable
cannot be parsed to a valid paths, it returns []. Every
directory contained will be checked for existence. If no directory can be found,
it will return undef.

=cut

sub getPath
{
	logDebug( File::Spec->path() );
	my @pathparts = File::Spec->path();
	if ( scalar(@pathparts) > 0 )
	{
		foreach my $p (@pathparts)
		{

			# cleanup path logically:
			$p = File::Spec->canonpath($p);
		}

		# remove duplicates:
		my %count;
		my @unique = grep { ++$count{$_} < 2 } @pathparts;
		@pathparts = @unique;
	}
	else
	{
		@pathparts = ();    # empty
		logWarn("No valid PATH found, falling back to empty path");
	}
	logDebug( "pathparts:", @pathparts );
	my @result = ();

	# check wether the directories do exist physically:
	foreach my $p (@pathparts)
	{
		if ( -d $p && -r $p )
		{
			push( @result, $p );
		}
		else
		{
			logInfo( "removed", $p,
				"from ENV{PATH} as it is not existing/readable anyway" );
		}
	}
	if ( scalar(@result) )
	{
		logDebug( "returning path:", @result );
		return \@result;
	}
	else
	{
		logWarn("no valid dirs found in path!");
		return undef;
	}
}

=item findInPath(what, [where])

findInPath will try to find the file specified by what in the list of paths
specified by where. It checks if the file is existing, readable and executable.
If found, it returns the full name of the file, otherwise it returns undef.

=cut

sub findInPath
{
	my $what = shift or graceful_die("need what parameter");
	my $path = shift or graceful_die("need path parameter");
	if ( not defined $path )
	{
		logWarn("Path contains no directories");
		return undef;
	}
	foreach my $d ( @{$path} )
	{
		my $checkfor = File::Spec->catfile( $d, $what );
		if ( -e $checkfor && -r $checkfor && -x $checkfor )
		{
			return $checkfor;
		}
	}
	return undef;
}

=item fetchFile(string filename)

fetchFile() will read the contents of file filename into a scalar and return it.
It fails on error.

=cut

sub fetchFile
{
	my $filename = shift;

	if ( not defined $filename )
	{
		graceful_die "No filename specified in fetchFile()";
	}
	elsif ( !-e $filename )
	{
		graceful_die "File '$filename' does not exist";
	}
	elsif ( !-r $filename )
	{
		graceful_die "File '$filename' is not readable";
	}

	open FILE, "<$filename" || graceful_die "Can't open file '$filename': $!";
	undef $/;
	my $data = <FILE>;
	close FILE || graceful_die "Can't close file '$filename': $!";
	return $data;
}

=item expand_tilde( string filename )

expand_tilde() will expand any correctly used tilde in a path to the home directory of the current user
E.g.:

   ~user
   ~user/blah
   ~
   ~/blah

=cut

sub expand_tilde
{
	my $f = shift || graceful_die("please supply a filename!");
	$f =~ s{ ^ ~ ( [^/]* ) }
		{ $1
				? (getpwnam($1))[7]
				: ( $ENV{HOME} || $ENV{LOGDIR}
						|| (getpwuid($>))[7]
					)
	}ex;
	return $f;
}

=item getPreferences( config file )

getPreferences() will read preferences from the system wide and private
configuration files. It returns a hash reference or fails on error. Optionally,
a config file to be read can be specified as a parameter. If an optional config
file is specified, only the system-wide config file is read and then the
specified one, while omitting the config file in the user's HOME.

=cut

sub getPreferences
{
	my $morerc       = shift;
	my @rc_locations = (
		File::Spec->catfile( '/etc/',           $_glb->{Name} . '.conf' ),
		File::Spec->catfile( '/usr/local/etc/', $_glb->{Name} . '.conf' ),
		File::Spec->catfile( $ENV{HOME},        '.' . $_glb->{Name} . 'rc' )
	);    # TODO try to make this more portable (different OS's/filesystems)
	if ( defined $morerc )
	{
		pop(@rc_locations);
		push( @rc_locations, $morerc );
	}
	my @rc_toread = ();
	foreach my $rc (@rc_locations)
	{
		logDebug( "Checking for config file", $rc );
		if ( -e $rc )
		{
			if ( -r $rc )
			{
				push( @rc_toread, $rc );
			}
		}
	}
	logDebug( "Using these config files: ", @rc_toread );
	if ( @rc_toread < 1 )
	{
		graceful_die("No configuration files found.");
	}
	my $cfg = {};
	foreach my $rc (@rc_toread)
	{
		open( CONFIG, "<$rc" ) || graceful_die("Can't open config file: $!");
		while (<CONFIG>)
		{
			chomp;
			s/^\s+//;
			s/\s+$//;
			s/\s+/ /g;
			s/\s*=\s*/ = /;
			if (/^dbusername = (\S+)$/i)
			{

				# db username
				$cfg->{dbusername} = $1;
			}
			elsif (/^dbpassword = (\S+)$/i)
			{

				#
				$cfg->{dbpassword} = $1;
			}
			elsif (/^dbhost = (\S+)$/i)
			{

				#
				$cfg->{dbhost} = $1;
			}
			elsif (/^backupdir = (\S+)$/i)
			{

				#
				$cfg->{backupdir} = expand_tilde($1);
			}
			elsif (/^databases = (\S+)$/i)
			{

				#
				$cfg->{databases} = $1;
			}
			elsif (/^exclude databases = (\S+)$/i)
			{

				#
				$cfg->{exclude_databases} = $1;
			}
			elsif (/^optimize_tables = (\S+)$/) {
				$cfg->{optimize_tables} = $1;
				if ( !( $cfg->{optimize_tables} =~ /^(0|1|yes|no|y|n|true|false|t|f)$/i )
				  )
				{
					logWarn( "Invalid 'optimize_tables' given:", $cfg->{optimize_tables} );
					$cfg->{optimize_tables} = undef;
				}
				elsif ( $cfg->{optimize_tables} =~ /^(0|no|n|false|f)$/i )
				{
					$cfg->{optimize_tables} = undef;    # false
				}
			}
			elsif (/^mysqldump = (\S+)$/i)
			{

				#
				$cfg->{mysqldump} = expand_tilde($1);
			}
			elsif (/^mysql = (\S+)$/i)
			{

				#
				$cfg->{mysql} = expand_tilde($1);
			}
			elsif (/^defaults-extra-file = (\S+)$/i)
			{

				#
				$cfg->{defaultsextrafile} = expand_tilde($1);
			}
			elsif (/^keep = (\S+)$/i)
			{

				#
				$cfg->{keepnumfiles} = $1;
				unless ( $cfg->{keepnumfiles} =~ /^\d+$/ )
				{
					logWarn(
						"Invalid value for 'keep' given:",
						"'" . $cfg->{keepnumfiles} . "'"
					);
					$cfg->{keepnumfiles} = undef;
				}
			}
			elsif (/^loglevel = (\S+)$/i)
			{

				#
				$cfg->{loglevel} = $1;
				unless ( $cfg->{loglevel} =~ /[0-5]/ )
				{
					logWarn( "Invalid loglevel given:", $cfg->{loglevel} );
					$cfg->{loglevel} = undef;
				}
			}
			elsif (/^use compression = (\S+)$/i)
			{

				#
				$cfg->{compression} = $1;
				if (
					!(
						$cfg->{compression} =~
						/^(0|1|yes|no|y|n|true|false|t|f)$/i
					)
				  )
				{
					logWarn( "Invalid 'use compression' given:",
						$cfg->{compression} );
					$cfg->{compression} = undef;
				}
				elsif ( $cfg->{compression} =~ /^(0|no|n|false|f)$/i )
				{
					$cfg->{compression} = 0;
				}
			}
			elsif (/^compression\s{0,1}tool = (\S+)$/i)
			{

				#
				$cfg->{compressiontool} = expand_tilde($1);
			}
			elsif (/^tar = (\S+)$/i)
			{

				#
				$cfg->{tar} = expand_tilde($1);
			}
			elsif (/^use syslog = (\S+)$/i)
			{

				#
				$cfg->{syslog} = $1;
				if ( !( $cfg->{syslog} =~ /^(0|1|yes|no|y|n|true|false|t|f)$/i )
				  )
				{
					logWarn( "Invalid 'use syslog' given:", $cfg->{syslog} );
					$cfg->{syslog} = undef;
				}
				elsif ( $cfg->{syslog} =~ /^(0|no|n|false|f)$/i )
				{
					$cfg->{syslog} = 0;    # false
				}
			}
			else
			{

				#NOP --- TODO: add list of allowed but ignored keywords...
			}
		}
		close CONFIG || graceful_die "Can't close config file: $!";
	}

	# some defaults:
	$cfg->{compression} = 1 unless defined $cfg->{compression};
	$cfg->{loglevel}    = 2 unless defined $cfg->{loglevel};
	$cfg->{syslog}      = 1 unless defined $cfg->{syslog};

	return $cfg;
}

=item fuFile (string filename, \string buffer)

fuFile() will fetch the content from the file specified by filename, unlink
it and put the data into the buffer specified. It will return true on
success, false if it could not get the data, and fails if it can't unlink
the file.

=cut

sub fuFile
{
	my $file   = shift || graceful_die("No file specified");
	my $buffer = shift || graceful_die("No buffer specified");

	if ( !ref($buffer) =~ /^SCALAR$/ )
	{
		graceful_die("Specified buffer is not a scalar reference!");
	}

	my $result = 1;    # default success

	eval { $$buffer = fetchFile($file); };
	if ( my $e = $@ )
	{                  # problem with fetchFile
		$result = 0;
	}
	else
	{
		if ( defined $$buffer && $$buffer eq '' )
		{              # output empty
			logInfo("File $file could be read but is empty"); # don't warn, this might be expected
		}
		else
		{              # output NOT empty
			logDebug( "Content from $file: " . $$buffer );
		}
		my $res = ( !-e $file ) * 2 || unlink $file;

# now, res has 3 possible values: -1 on error, 1 on success, 2 on 'file was inexistant from the beginning'
		if ( $res == -1 )
		{
			$result = 0;
			die "Could not remove file '$file'";
		}
	}
	return $result;
}

=item mydump( {db => string, all => bool, file => string} )

mydump() will dump the database(s) to the specified file.

=cut

sub mydump
{

	# TODO speed/safety option
	my $param = shift || graceful_die('Got no parameters');
	my $msg   = shift || graceful_die('Got no msg parameter');

	logDebug(1);

	if ( !ref($msg) =~ /^SCALAR$/ )
	{
		graceful_die("Specified msg-buffer is not a scalar reference!");
	}

	# parse parameters:
	unless ( ref($param) =~ /^HASH$/ )
	{
		graceful_die('Parameter is not a hash!');
	}
	if ( defined $param->{db} && defined $param->{all} )
	{
		graceful_die('invalid params: all and db at the same time!');
	}
	if ( !defined $param->{file} )
	{
		graceful_die('you need to give me the filename!!');
	}

	my @cmd = ( getConfigValue('mysqldump') );

	# if a defaults-extra-file was specified, use it!
	if ( my $defaultsextrafile = getConfigValue('defaultsextrafile') )
	{
			push( @cmd, "--defaults-extra-file=$defaultsextrafile" );
	}
	else # otherwise, rely on direct username/password/host from cfg:
	{
		if ( my $u = getConfigValue('dbusername') )
		{
			push( @cmd, '--user' );
			push( @cmd, $u );
		}
		;    # if no user, my.cnf is used by the mysql tools
		if ( my $p = getConfigValue('dbpassword') )
		{
			push( @cmd, "--password=$p" );
		}
		if ( my $h = getConfigValue('dbhost') )
		{
			push( @cmd, '--host' );
			push( @cmd, $h );
		}
	}

	push( @cmd,
		'--lock-tables', '--complete-insert', '--add-drop-table',
		'--quick',       '--quote-names' );

	if ( defined $param->{all} && not defined $param->{db} )
	{
		push( @cmd, '--all-databases' );
		logInfo("Going to dump all databases");
	}
	elsif ( defined $param->{db} && not defined $param->{all} )
	{
		push( @cmd, $param->{db} );
		logInfo( "Going to dump database", "`" . $param->{db} . "`" );
	}
	else
	{
		graceful_die(
"No specification on what to backup (all databases, or only specific ones)."
		);
	}

	my $output_target = $param->{file};
	if ( my $result = _system( \@cmd, $output_target ) )
	{
		logInfo("Successfully dumped to $output_target");
		$$msg = undef;
		return 1;
	}
	else
	{

		# get the command line in a string and hide password:
		my $cmdstr = join( ' ', @cmd );
		if ( my $p = getConfigValue('dbpassword') )
		{
			$cmdstr =~ s/$p/xxxxxx/;
		}

		# log it:
		logWarn( "Command failed: ", $cmdstr );
		logWarn("An error occured while dumping");
		my $result = undef;
		eval { $result = fuFile( $output_target, $msg ); };
		if ( my $e = $@ )
		{    # exception!
			$$msg = "fuFile threw an exception: " . $e;
		}
		elsif ( !$result )
		{
			$$msg = "fuFile could not read data from $output_target";
		}
		return undef;
	}
}

=item makeNativeZip( directory, workdir, zipfilename)

makeNativeZip() will create the zip file using native Perl routines/libraries.
Returns undef on failure or the filename of the created archive on success.

=cut

sub makeNativeZip
{
	my $files       = shift;
	my $workdir     = shift;
	my $zipfilename = shift;

	logDebug("files: @{$files}");
	logDebug("workdir: $workdir");
	logDebug("zipfilename: $zipfilename");

	chdir $workdir || graceful_die("Could not change to $workdir: $!");

	if ( my $e = &try_to_use("Archive::Zip") )
	{
		logWarn('Although compression was requested, it cannot be used, as Archive::Zip is not available');
		return undef;
	}
	# we don't import error codes or constants, because all we do is check if the result
	# of writeToFileNamed() is zero

	my $zip = Archive::Zip->new();

	my $compresslevel = ( getConfigValue('compression') ) ? 9 : 0;

	# Add a file from disk
	my $file_member;
	foreach my $file ( @{$files} )
	{
		$file = File::Basename::basename($file);

		$file_member = $zip->addFile($file)
		  || logWarn("Can't add the '$file' file");
		$file_member->desiredCompressionLevel($compresslevel)
		  || logWarn("Can't compress using $compresslevel method");
	}

	# Save the Zip file
	my $result = $zip->writeToFileNamed($zipfilename);
	if ( $result == 0  ) # AZ_OK
	{
		return $zipfilename;
	}
	else
	{
		logWarn( "create_zip returns:'", $result, "\n" );
		return undef;
	}
}

=item makeNativeTar( [files], workdir, tarfilename)

makeNativeTar() will create the tar file using native Perl routines/libraries.
Returns undef on failure or the filename of the created archive on success.

=cut

sub makeNativeTar
{
	my $files       = shift;
	my $workdir     = shift;
	my $tarfilename = shift;

	chdir $workdir || graceful_die("Could not change to $workdir: $!");
	foreach my $f ( @{$files} )
	{    # adjust filenames to relative paths
		$f = File::Spec->abs2rel($f);    # uses cwd() as base
		unless ( -f $f )
		{
			logWarn( $f, "will probably not be added to the tar, but will continue and try");
		}
	}

	if ( scalar @{$files} < 1 )
	{
		graceful_die "Nothing to tar!";
	}
	my $compression = undef;
	if ( getConfigValue('compression') )
	{
		eval "use IO::Zlib";
		if ( my $e = $@ )
		{
			logWarn('Although compression was requested, it cannot be used, as IO::Zlib is not available:', $e);
		}
		else
		{
			$tarfilename .= ".gz";
			$compression = 1;    # default compression level, other allowed: 2-9
		}
	}
	my $result =
	  Archive::Tar->create_archive( $tarfilename, $compression, @{$files} );
	if ( !$result )
	{                            # problem
		logWarn(
			"create_archive returns:'",
			$result, "', which means:",
			Archive::Tar->error()
		);
		return undef;
	}
	else
	{
		return $tarfilename;
	}
}

=item makeExternalTar( [files], workdir, tarfilename)

makeNativeTar() will create the tar file using external command line utilities.
Returns undef on failure or the filename of the created archive on success.

=cut

sub makeExternalTar
{
	my $tar       = shift || graceful_die("Need the tar utility as parameter");
	my $directory = shift || graceful_die("Need the directory to be tarred");
	my $workdir   = shift
	  || graceful_die("Need the working directory for tarring");
	my $tarfilename = shift || graceful_die("Need the tar filename");

	logDebug("directory to be tarred: $directory");
	logDebug("workdir: $workdir");
	logDebug("tarfilename: $tarfilename");

	chdir $workdir || graceful_die("Could not change to $workdir: $!");
	if ( !-d $directory )
	{
		graceful_die "Directory $directory for tarring does not exist!";
	}
	my $s = File::Spec->abs2rel( $directory, $workdir );    # uses cwd() as base
	unless ( -d $s )
	{
		logErr( $s, "is not a subdirectory of $directory, will not be able to create correct pathnames in tar archive");
		$s = $directory;
	}

	my $compresstool = undef;
	if ( getConfigValue('compression') )
	{    # compression was specified!
		if ( $compresstool =
			expandExecutableName( getConfigValue('compressiontool'), 'gzip' ) )
		{
			logInfo( "Will use", $compresstool, "as the compression tool" );
		}
		else
		{
			logWarn('Although compression was requested, it cannot be used, as gzip is not available');
		}
	}

	my @ccmd = ();
	if ( defined $compresstool )
	{
		logDebug("Found compression tool, configuring command...");
		push( @ccmd, '--use-compress-program' );
		push( @ccmd, $compresstool );
		if ( $compresstool =~ /gzip$/ )
		{
			$tarfilename .= ".gz";
		}
		elsif ( $compresstool =~ /bzip2$/ )
		{
			$tarfilename .= ".bz2";
		}
	}

	my @cmd = ( $tar, @ccmd, '-cf', $tarfilename, $s );
	logDebug( "command: ", @cmd );
	if ( my $result = _system( \@cmd, '' ) )
	{
		return $tarfilename;
	}
	else
	{

		# get the command line in a string
		my $cmdstr = join( ' ', @cmd );
		logWarn( "Command failed: ", $cmdstr );
		logWarn("An error occured while tarring");
		return undef;
	}
}

=item expandExecutableName(param, seed)

expandExecutableName() will try to expand the given name of an executable to a fully qualified, absolute filename. It takes two parameters: the first one is usually a user-supplied path or filename and the second parameter is a system default bare executable name in case no user supplied value is available.

   e.g.: expandExecutableName('/home/galaxy/bin/gzip', undef );
         expandExecutableName(undef, 'gzip');

         both examples make sense

=cut

sub expandExecutableName
{
	my $param = shift;
	my $seed  = shift || graceful_die("need seed");

	if ( defined $param )
	{
		if ( !File::Spec->file_name_is_absolute($param) )
		{    # something was specified
			if ( my $x = findInPath( $param, getPath() ) )
			{    # it was found in the path
				logDebug(
"$param was specified but still found dynamically, as it was not specified as an absolute path:",
					$x
				);
				return $x;
			}
			else
			{
				logWarn(
"$param was specified but could not be found or is not executable:",
					$param
				);
				return undef;
			}
		}
		else
		{    # absolute path was specified
			unless ( -x $param )
			{
				logWarn(
"$param was specified but could not be found or is not executable:",
					$param
				);
				return undef;
			}
			logInfo("$param was found");
			return $param;
		}
	}
	else
	{    # no '$param' was specified
		if ( my $x = findInPath( $seed, getPath() ) )
		{
			logInfo( "Dynamically found $seed:", $x );
			return $x;
		}
		else
		{
			logWarn(
"$seed was not specified and could not be found or is not executable."
			);
			return undef;
		}
	}

}

=item makeTar(directory, [files], workdir, tarfilename)

makeTar() will create a tar file.
TODO: more POD

=cut

sub makeTar
{
	my $directory   = shift;
	my $files       = shift;
	my $workdir     = shift;
	my $tarfilename = shift;

	# find tar:
	if ( my $exttar = expandExecutableName( getConfigValue('tar'), 'tar' ) )
	{

		# external utilities
		logInfo("running external tar");
		return makeExternalTar( $exttar, $directory, $workdir, $tarfilename );
	}
	else
	{

		# native Perl
		if ( my $e = &try_to_use("Archive::Tar") )
		{
			logErr($e);
			graceful_die(
"Found no command line tar utility, and no Archive::Tar Perl module!"
			);
		}
		else
		{
			logInfo("Will use native Perl tar");
			return makeNativeTar( $files, $workdir, $tarfilename );
		}
	}
}

=item purgeOldFiles(directory, number_of_files_to_keep)

purgeOldFiles() will delete all files older than the 'number_of_files_to_keep'
files in the specified 'directory'.

=cut

sub purgeOldFiles
{
	my $dir = shift
	  || graceful_die("need to give a directory for purgeOldFiles!");
	my $keep = shift;

	if ( defined $keep && !( $keep =~ /^\d+$/ ) )
	{
		logWarn( "Number of files to keep received is not a digit:", $keep );
		$keep = undef;
	}
	if ( !defined $keep )
	{
		logInfo("Falling back to keeping 7 backup files.");
		$keep = 7;    # hardcoded default
	}
	elsif ( $keep < 1 )
	{
		logErr(
"Number of files to keep is zero? No backup will be there! Check your config!"
		);
		$keep = 0;
	}

	# Must be a directory.
	unless ( -d $dir )
	{
		logErr( -e _ ? "$dir: not a directory" : "$dir: not existing" );
		return undef;
	}

	# We need write access since we are going to delete files.
	unless ( -w _ )
	{
		logErr("$dir: no write access");
		return undef;
	}

	# We need read acces since we are going to ge the file list.
	unless ( -r _ )
	{
		logErr("$dir: no read access");
		return undef;
	}

	# Probably need this as weel, don't know.
	unless ( -x _ )
	{
		logErr("$dir: no access");
		return undef;
	}

	# Gather file names and ages.
	opendir( DIR, $dir )
	  or logErr("dir: $!");    # shouldn't happen -- we've checked!
	my @files;
	foreach ( readdir(DIR) )
	{
		next if /^\./;
		next unless -f File::Spec->catfile( $dir, $_ );
		push( @files, [ File::Spec->catfile( $dir, $_ ), -M _ ] );
	}
	closedir(DIR);

	logDebug( "$dir: total of", scalar(@files), "files" );
	logDebug( "the files:", @{ [ map { $_->[0] } @files ] } );

	# Is there anything to do?
	if ( @files <= abs($keep) )
	{
		logNotice("$dir: below limit");
		return 1;    # success
	}

	# Sort on age. Also reduces the list to file names only.
	my @sorted = map { $_->[0] } sort { $b->[1] <=> $a->[1] } @files;
	logDebug("$dir: sorted: @sorted");

	# Splice out the files to keep.
	if ( $keep < 0 )
	{

		# Keep the oldest files (head of the list).
		splice( @sorted, 0, -$keep );
	}
	else
	{

		# Keep the newest files (tail of the list).
		splice( @sorted, @sorted - $keep, $keep );
	}

	# Remove the rest.
	foreach (@sorted)
	{
		logDebug("trying to remove $_");
		my $r = ( !-e $_ ) * 2 || unlink $_;

# now, result has 3 possible values: 0 on error, 1 on success, 2 on 'file was inexistant from the beginning'
		logNotice("File $_ could not be removed, it was already gone.")
		  if $r == 2;
		if ( $r == 0 )
		{
			logErr("Could not remove $_: $!");

# we do not fail, because we want to avoid disk-overflows when the admin has gone on vacation...
# so we continue trying the rest of the files...
		}
	}
	return 1;
}

=item version

Prints version information and exits.

=cut

sub version
{
	my $VERSION = '0.8';
	print $VERSION, "\n";
	exit 0;
}

=item help

Feeds this script to `perldoc`

=cut

sub help
{
	print "Feeding myself to perldoc, please wait....\n";
	exec( 'perldoc', '-t', $0 ) or die "$0: can't fork: $!\n";
	exit(0);
}

##### MAIN ###################################################################
&bootinit();

# get command line arguments:
$_glb->{opts} = undef;
Getopt::Long::config( 'bundling', 'no_ignore_case' );
GetOptions(
	'version|V'       => \$_glb->{opts}->{version},
	'help|h'          => \$_glb->{opts}->{help},
	'config-file|c=s' => \$_glb->{opts}->{cfg}
  )
  or exit 1;

# some routines that do no need further initialization:
&version() if defined $_glb->{opts}->{version};
&help()    if defined $_glb->{opts}->{help};

# config:
&cfginit();

if ( !-d getConfigValue('backupdir') )
{
	graceful_die( "backupdir does not exist: " . getConfigValue('backupdir') );
}

# set this before doing anything
if ( !defined getConfigValue('mysql') )
{
	if ( my $m = findInPath( 'mysql', getPath() ) )
	{
		setConfigValue( 'mysql', $m );
	}
	elsif ( $m = findInPath( 'mysql.exe', getPath() ) )
	{
		setConfigValue( 'mysql', $m );
	}
	else
	{
		graceful_die("mysql executable could not be found");
	}
}
else
{
	unless ( -x getConfigValue('mysql') )
	{
		graceful_die( "configured mysql '"
			  . getConfigValue('mysql')
			  . "' executable could not be found/is not executable" );
	}
}
if ( !defined getConfigValue('mysqldump') )
{
	if ( my $m = findInPath( 'mysqldump', getPath() ) )
	{
		setConfigValue( 'mysqldump', $m );
	}
	elsif ( $m = findInPath( 'mysqldump.exe', getPath() ) )
	{
		setConfigValue( 'mysqldump', $m );
	}
	else
	{
		graceful_die("mysqldump executable could not be found");
	}
}
else
{
	unless ( -x getConfigValue('mysqldump') )
	{
		graceful_die( "configured mysqldump '"
			  . getConfigValue('mysqldump')
			  . "' executable could not be found/is not executable" );
	}
}

# fetch names of all existing databases, that I can see using SHOW DATABASES:
# also serves as basic mysql connectivity test...
my $alldbs = [];
@{$alldbs} = ldb_databases();

# check that at least one database was found:
if ( scalar @{$alldbs} <= 0 )
{
	graceful_die(
"Something must be wrong! The number of databases found is zero!"
	);
}

# see what the configuration says about what to backup and check consistency:
my $backupdbs = [];
if ( defined getConfigValue('databases') )
{
	my @confdbs = split( ',', getConfigValue('databases') );
	my $alldbshashref = undef;
	%{$alldbshashref} = map { $_ => $_ } @{$alldbs};
	foreach (@confdbs)
	{
		s/^\s+//;
		s/\s+$//;    # remove whitespaces
		if ( defined $alldbshashref->{$_} )
		{
			push( @{$backupdbs}, $_ );
		}
		else
		{
			logWarn(
"The specified database $_ does not exist. Will not try to backup."
			);
		}
	}
}
else
{

	# backup all databases:
	$backupdbs = $alldbs;
}

# do not backup the databases specified through "exclude databases = dfg,dfh,jhhj":
if ( defined getConfigValue('exclude_databases') )
{
	my $tempdbs    = [];      # temporary var
	my $dbshashref = undef;
	%{$dbshashref} = map { $_ => $_ } @{$backupdbs};
	my @exclude_databases = split( ',', getConfigValue('exclude_databases') );
	foreach (@exclude_databases)
	{
		s/^\s+//;
		s/\s+$//;             # remove whitespaces
	}
	my $excludedbshashref = undef;
	%{$excludedbshashref} = map { $_ => $_ } @exclude_databases;
	foreach ( @{$backupdbs} )
	{
		if ( !defined $excludedbshashref->{$_} )
		{
			push( @{$tempdbs}, $_ );
		}
		else
		{
			logInfo("The specified database $_ will not be backed up.");
		}
	}
	$backupdbs = $tempdbs;
}

# check that at least one database is in the set:
if ( scalar @{$backupdbs} <= 0 )
{
	graceful_die(
"Something must be wrong! The number of databases found to be backed up is zero!"
	);
}

# go through the list of db's to be dumped:
my $dumps;
foreach my $d ( @{$backupdbs} )
{
	logDebug( "dumping db:", $d );
	my $message = undef;
	if (
		my $result = mydump(
			{ db => $d, file => File::Spec->catfile( hostDir(), "$d.sql" ) },
			\$message
		)
	  )
	{

		# NOP, successfully dumped
		push( @{$dumps}, File::Spec->catfile( hostDir(), "$d.sql" ) );
	}
	else
	{
		logErr($message);
	}
}

my @parts = File::Spec->splitdir( hostDir() );

if ( $^O !~ /MSWin32/ )
{
	my $tarname = $parts[-1] . ".tar";
	logDebug( 'using tar filename:', $tarname );
	if ( -e getConfigValue('backupdir') . $tarname )
	{
		graceful_die( "Backup with filename "
			  . File::Spec->catfile( getConfigValue('backupdir'), $tarname )
			  . " already exists!" );
	}
	if (
		my $createdtar = makeTar(
			hostDir(), $dumps, workDir(),
			File::Spec->catfile( getConfigValue('backupdir'), $tarname )
		)
	  )
	{    # problem creating tar
		logInfo( "Successfully tarred dump(s) to", $createdtar );
	}
	else
	{
		logWarn( "Will unlink the unsuccessfully created tar file:", $tarname );
		unlink $tarname;
		graceful_die("Tar file unlinked. Quitting.");
	}
}
else
{
	my $zipname = $parts[-1] . ".zip";
	logDebug( 'using zip filename:', $zipname );
	if ( -e getConfigValue('backupdir') . $zipname )
	{
		graceful_die( "Backup with filename "
			  . File::Spec->catfile( getConfigValue('backupdir'), $zipname )
			  . " already exists!" );
	}
	if (
		my $createdzip = makeNativeZip(
			$dumps, hostDir(),
			File::Spec->catfile( getConfigValue('backupdir'), $zipname )
		)
	  )
	{    # problem creating tar
		logInfo( "Successfully zipped dump(s) to", $createdzip );
	}
	else
	{
		logWarn( "Will unlink the unsuccessfully created zip file:", $zipname );
		unlink $zipname;
		graceful_die("Zip file unlinked. Quitting.");
	}
}

unless (
	purgeOldFiles(
		getConfigValue('backupdir'), getConfigValue('keepnumfiles')
	)
  )
{    # problem
	graceful_die("Could not cleanup old backups...");
}

# OPTIMIZE TABLES AFTER DUMPING
if (getConfigValue('optimize_tables')) {
	logInfo('Optimizing tables');
	foreach my $database ( @{$backupdbs} )
	{
		next if ($database eq 'information_schema'); # don't optimize that one ;-)
		logDebug( "listing tables in db:", $database );
		my @tables = ldb_database_tables($database);
		logDebug( "optimizing tables in db:", $database );
		foreach my $table (@tables) {
			logDebug($table);
			myoptimize($database, $table);
		}
	}
}

cleanup();

############################################################
# POD Footer
############################################################

=back
