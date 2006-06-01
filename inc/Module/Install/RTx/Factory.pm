#line 1
package Module::Install::RTx::Factory;
use Module::Install::Base; @ISA = qw(Module::Install::Base);

use strict;
use File::Basename ();

sub RTxInitDB {
    my ($self, $action) = @_;

    unshift @INC, substr(delete($INC{'RT.pm'}), 0, -5) if $INC{'RT.pm'};

    require RT;
    unshift @INC, "$RT::LocalPath/lib" if $RT::LocalPath;

    $RT::SbinPath ||= $RT::LocalPath;
    $RT::SbinPath =~ s/local$/sbin/;

    foreach my $file ($RT::CORE_CONFIG_FILE, $RT::SITE_CONFIG_FILE) {
        next if !-e $file or -r $file;
        die "No permission to read $file\n-- please re-run $0 with suitable privileges.\n";
    }

    RT::LoadConfig();

    my $lib_path = File::Basename::dirname($INC{'RT.pm'});
    my @args = ("-Ilib");
    push @args, "-I$RT::LocalPath/lib" if $RT::LocalPath;
    push @args, (
        "-I$lib_path",
        "$RT::SbinPath/rt-setup-database",
        "--action"      => $action,
        "--datadir"     => "etc",
        "--datafile"    => "etc/initialdata",
        "--dba"         => $RT::DatabaseUser,
        "--prompt-for-dba-password" => ''
    );
    print "$^X @args\n";
    (system($^X, @args) == 0) or die "...returned with error: $?\n";
}

sub RTxFactory {
    my ($self, $RTx, $name, $drop) = @_;
    my $namespace = "$RTx\::$name";

    $self->RTxInit;

    my $dbh = $RT::Handle->dbh;
    # get all tables out of database
    my @tables = $dbh->tables;
    my ( %tablemap, %typemap, %modulemap );
    my $driver = $RT::DatabaseType;

    my $CollectionBaseclass = 'RT::SearchBuilder';
    my $RecordBaseclass     = 'RT::Record';
    my $LicenseBlock = << '.';
# BEGIN LICENSE BLOCK
# 
# END LICENSE BLOCK
.
    my $Attribution = << '.';
# Autogenerated by Module::Intall::RTx::Factory
# WARNING: THIS FILE IS AUTOGENERATED. ALL CHANGES TO THIS FILE WILL BE LOST.  
# 
# !! DO NOT EDIT THIS FILE !!
#

use strict;
.
    my $RecordInit = '';

    @tables = map { do { {
	my $table = $_;
	$table =~ s/.*\.//g;
	$table =~ s/\W//g;
	$table =~ s/^\Q$name\E_//i or next;
	$table ne 'sessions' or next;

	$table = ucfirst(lc($table));
	$table =~ s/$_/\u$_/ for qw(field group custom member value);
	$table =~ s/(?<=Scrip)$_/\u$_/ for qw(action condition);
	$table =~ s/$_/\U$_/ for qw(Acl);
	$table = $name . '_' . $table;

	$tablemap{$table}  = $table;
	$modulemap{$table} = $table;
	if ( $table =~ /^(.*)s$/ ) {
	    $tablemap{$1}  = $table;
	    $modulemap{$1} = $1;
	}
	$table;
    } } } @tables;

    $tablemap{'CreatedBy'} = 'User';
    $tablemap{'UpdatedBy'} = 'User';

    $typemap{'id'}            = 'ro';
    $typemap{'Creator'}       = 'auto';
    $typemap{'Created'}       = 'auto';
    $typemap{'Updated'}       = 'auto';
    $typemap{'UpdatedBy'}     = 'auto';
    $typemap{'LastUpdated'}   = 'auto';
    $typemap{'LastUpdatedBy'} = 'auto';

    $typemap{lc($_)} = $typemap{$_} for keys %typemap;

    foreach my $table (@tables) {
	if ($drop) {
	    $dbh->do("DROP TABLE $table");
	    $dbh->do("DROP sequence ${table}_id_seq") if $driver eq 'Pg';
	    $dbh->do("DROP sequence ${table}_seq") if $driver eq 'Oracle';
	    next;
	}

	my $tablesingle = $table;
	$tablesingle =~ s/^\Q$name\E_//i;
	$tablesingle =~ s/s$//;
	my $tableplural = $tablesingle . "s";

	if ( $tablesingle eq 'ACL' ) {
	    $tablesingle = "ACE";
	    $tableplural = "ACL";
	}

	my %requirements;

	my $CollectionClassName = $namespace . "::" . $tableplural;
	my $RecordClassName     = $namespace . "::" . $tablesingle;

	my $path = $namespace;
	$path =~ s/::/\//g;

	my $RecordClassPath     = $path . "/" . $tablesingle . ".pm";
	my $CollectionClassPath = $path . "/" . $tableplural . ".pm";

	#create a collection class
	my $CreateInParams;
	my $CreateOutParams;
	my $ClassAccessible = "";
	my $FieldsPod       = "";
	my $CreatePod       = "";
	my $CreateSub       = "";
	my %fields;
	my $sth = $dbh->prepare("DESCRIBE $table");

	if ( $driver eq 'Pg' ) {
	    $sth = $dbh->prepare(<<".");
  SELECT a.attname, format_type(a.atttypid, a.atttypmod),
         a.attnotnull, a.atthasdef, a.attnum
    FROM pg_class c, pg_attribute a
   WHERE c.relname ILIKE '$table'
         AND a.attnum > 0
         AND a.attrelid = c.oid
ORDER BY a.attnum
.
	}
	elsif ( $driver eq 'mysql' ) {
	    $sth = $dbh->prepare("DESCRIBE $table");
	}
	else {
	    die "$driver is currently unsupported";
	}

	$sth->execute;

	while ( my $row = $sth->fetchrow_hashref() ) {
	    my ( $field, $type, $default );
	    if ( $driver eq 'Pg' ) {

		$field   = $row->{'attname'};
		$type    = $row->{'format_type'};
		$default = $row->{'atthasdef'};

		if ( $default != 0 ) {
		    my $tth = $dbh->prepare(<<".");
SELECT substring(d.adsrc for 128)
  FROM pg_attrdef d, pg_class c
 WHERE c.relname = 'acct'
       AND c.oid = d.adrelid
       AND d.adnum = $row->{'attnum'}
.
		    $tth->execute();
		    my @default = $tth->fetchrow_array;
		    $default = $default[0];
		}

	    }
	    elsif ( $driver eq 'mysql' ) {
		$field   = $row->{'Field'};
		$type    = $row->{'Type'};
		$default = $row->{'Default'};
	    }

	    $fields{$field} = 1;

	    #generate the 'accessible' datastructure

	    if ( $typemap{$field} eq 'auto' ) {
		$ClassAccessible .= "        $field => 
		    {read => 1, auto => 1,";
	    }
	    elsif ( $typemap{$field} eq 'ro' ) {
		$ClassAccessible .= "        $field =>
		    {read => 1,";
	    }
	    else {
		$ClassAccessible .= "        $field => 
		    {read => 1, write => 1,";

	    }

	    $ClassAccessible .= " type => '$type', default => '$default'},\n";

	    #generate pod for the accessible fields
	    $FieldsPod .= $self->_pod(<<".");
^head2 $field

Returns the current value of $field. 
(In the database, $field is stored as $type.)

.

	    unless ( $typemap{$field} eq 'auto' || $typemap{$field} eq 'ro' ) {
		$FieldsPod .= $self->_pod(<<".");

^head2 Set$field VALUE


Set $field to VALUE. 
Returns (1, 'Status message') on success and (0, 'Error Message') on failure.
(In the database, $field will be stored as a $type.)

.
	    }

	    $FieldsPod .= $self->_pod(<<".");
^cut

.

	    if ( $modulemap{$field} ) {
		$FieldsPod .= $self->_pod(<<".");
^head2 ${field}Obj

Returns the $modulemap{$field} Object which has the id returned by $field


^cut

sub ${field}Obj {
	my \$self = shift;
	my \$$field =  ${namespace}::$modulemap{$field}->new(\$self->CurrentUser);
	\$$field->Load(\$self->__Value('$field'));
	return(\$$field);
}
.
		$requirements{ $tablemap{$field} } =
		"use ${namespace}::$modulemap{$field};";

	    }

	    unless ( $typemap{$field} eq 'auto' || $field eq 'id' ) {

		#generate create statement
		$CreateInParams .= "                $field => '$default',\n";
		$CreateOutParams .=
		"                         $field => \$args{'$field'},\n";

		#gerenate pod for the create statement	
		$CreatePod .= "  $type '$field'";
		$CreatePod .= " defaults to '$default'" if ($default);
		$CreatePod .= ".\n";

	    }

	}

	$CreateSub = <<".";
sub Create {
    my \$self = shift;
    my \%args = ( 
$CreateInParams
		\@_);
    \$self->SUPER::Create(
$CreateOutParams);

}
.
	$CreatePod .= "\n=cut\n\n";

	my $CollectionClass = $LicenseBlock . $Attribution . $self->_pod(<<".") . $self->_magic_import($CollectionClassName);

^head1 NAME

$CollectionClassName -- Class Description

^head1 SYNOPSIS

use $CollectionClassName

^head1 DESCRIPTION


^head1 METHODS

^cut

package $CollectionClassName;

use $CollectionBaseclass;
use $RecordClassName;

use vars qw( \@ISA );
\@ISA= qw($CollectionBaseclass);


sub _Init {
    my \$self = shift;
    \$self->{'table'} = '$table';
    \$self->{'primary_key'} = 'id';

.

    if ( $fields{'SortOrder'} ) {

	$CollectionClass .= $self->_pod(<<".");

# By default, order by name
\$self->OrderBy( ALIAS => 'main',
		FIELD => 'SortOrder',
		ORDER => 'ASC');
.
    }
    $CollectionClass .= $self->_pod(<<".");
    return ( \$self->SUPER::_Init(\@_) );
}


^head2 NewItem

Returns an empty new $RecordClassName item

^cut

sub NewItem {
    my \$self = shift;
    return($RecordClassName->new(\$self->CurrentUser));
}
.

    my $RecordClassHeader = $Attribution . "

^head1 NAME

$RecordClassName


^head1 SYNOPSIS

^head1 DESCRIPTION

^head1 METHODS

^cut

package $RecordClassName;
use $RecordBaseclass; 
";

    foreach my $key ( keys %requirements ) {
	$RecordClassHeader .= $requirements{$key} . "\n";
    }
    $RecordClassHeader .= <<".";

use vars qw( \@ISA );
\@ISA= qw( $RecordBaseclass );

sub _Init {
my \$self = shift; 

\$self->Table('$table');
\$self->SUPER::_Init(\@_);
}

.

    my $RecordClass = $LicenseBlock . $RecordClassHeader . $self->_pod(<<".") . $self->_magic_import($RecordClassName);

$RecordInit

^head2 Create PARAMHASH

Create takes a hash of values and creates a row in the database:

$CreatePod

$CreateSub

$FieldsPod

sub _CoreAccessible {
    {
    
$ClassAccessible
}
};

.

	print "About to make $RecordClassPath, $CollectionClassPath\n";
	`mkdir -p $path`;

	open( RECORD, ">$RecordClassPath" );
	print RECORD $RecordClass;
	close(RECORD);

	open( COL, ">$CollectionClassPath" );
	print COL $CollectionClass;
	close(COL);

    }
}

sub _magic_import {
    my $self = shift;
    my $class = ref($self) || $self;

    #if (exists \$warnings::{unimport})  {
    #        no warnings qw(redefine);

    my $path = $class;
    $path =~ s#::#/#gi;


    my $content = $self->_pod(<<".");
        eval \"require ${class}_Overlay\";
        if (\$@ && \$@ !~ qr{^Can't locate ${path}_Overlay.pm}) {
            die \$@;
        };

        eval \"require ${class}_Vendor\";
        if (\$@ && \$@ !~ qr{^Can't locate ${path}_Vendor.pm}) {
            die \$@;
        };

        eval \"require ${class}_Local\";
        if (\$@ && \$@ !~ qr{^Can't locate ${path}_Local.pm}) {
            die \$@;
        };




^head1 SEE ALSO

This class allows \"overlay\" methods to be placed
into the following files _Overlay is for a System overlay by the original author,
_Vendor is for 3rd-party vendor add-ons, while _Local is for site-local customizations.  

These overlay files can contain new subs or subs to replace existing subs in this module.

If you'll be working with perl 5.6.0 or greater, each of these files should begin with the line 

   no warnings qw(redefine);

so that perl does not kick and scream when you redefine a subroutine or variable in your overlay.

${class}_Overlay, ${class}_Vendor, ${class}_Local

^cut


1;
.

    return $content;
}

sub _pod {
    my ($self, $text) = @_;
    $text =~ s/^\^/=/mg;
    return $text;
}
