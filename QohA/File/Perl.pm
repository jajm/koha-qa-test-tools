package QohA::File::Perl;

use Smart::Comments  -ENV;

use Modern::Perl;
use File::Basename;
use Moo;
extends 'QohA::File';

use Test::Perl::Critic::Progressive(':all');
use Perl::Critic qw[critique];
use Pod::Coverage;
use IPC::Cmd qw[can_run run];
use Cwd qw( abs_path );

use QohA::Git;


our $pc_rc =  dirname( abs_path( $INC{'QohA/File/Perl.pm'} ) ) . '/../../perlcriticrc';
die "Koha's $pc_rc file is missing..." unless  ( -e  $pc_rc );

sub run_checks {
    my ($self, $cnt) = @_;

    my $r;

    # Check perl critic
    $r = $self->check_critic();
    $self->SUPER::add_to_report('critic', $r);

    # Check perl -cw
    $r = $self->check_valid();
    $self->SUPER::add_to_report('valid', $r);

    # Check pod (Pod::Checker)
    $r = $self->check_pod();
    $self->SUPER::add_to_report('pod', $r);

    # Check pod coverage (Pod::Coverage)
    if ( $self->path =~ qr/\.pm$/ ) {
        $r = $self->check_pod_coverage();
        $self->SUPER::add_to_report('pod coverage', $r);
    }

    # Check patterns
    $r = $self->check_forbidden_patterns($cnt);
    $self->SUPER::add_to_report('forbidden patterns', $r);

    # Check spelling
    $r = $self->check_spelling();
    $self->SUPER::add_to_report('spelling', $r);

    return $self->SUPER::run_checks($cnt);
}

sub check_critic {
    my ($self) = @_;
    my ( @ok, @ko );

    # Generate a perl critic progressive file in /tmp
    my $conf = $self->path . ".pc";
    $conf =~ s|/|-|g;
    $conf = "/tmp/$conf";

    # If it is the first pass, we have to remove the old configuration file
    if ( $self->pass == 0 ) {
        qx|rm $conf| if ( -e $conf ) ;
    }

    # If the file does not exist anymore, we return 0
    unless ( -e $self->path ) {
        $self->new_file(1);
        return 0;
    }

    # If first pass returns 0 then the file did not exist
    # And we have to pass Perl::Critic instead of Test::Perl::Critic::Progressive
    if ( $self->report->tasks->{critic}
            and $self->new_file ) {
        my $critic = Perl::Critic->new(-profile => $pc_rc);
        # Serialize the violations to strings
        my @violations = map {
            my $v = $_; chomp $v; "$v";
        } $critic->critique($self->path);
        return \@violations;
    }

    # Check with Test::Perl::Critic::Progressive
    my $cmd = qq{
        perl -e "use Test::Perl::Critic::Progressive(':all');
        set_critic_args(-profile => '$pc_rc');
        set_history_file('$conf');
        progressive_critic_ok('} . $self->path . qq{')"};

    my ( $success, $error_code, $full_buf, $stdout_buf, $stderr_buf ) =
      run( command => $cmd, verbose => 0 );

    # If it is the first pass, we stop here
    return 0 if $self->pass == 0;

    # And if it is a success (ie. no regression)
    return 0 if $success;

    # Encapsulate the potential errors
    my @errors;
    for my $line (@$full_buf) {
        chomp $line;

        $line =~ s/\n//g;
        $line =~ s/Expected no more than.*$//g;

        next if $line =~ qr/Too many Perl::Critic violations/;

        push @errors, $line if $line =~ qr/violation/;
    }

    return @errors
        ? \@errors
        : 0;
}


sub check_valid {
    my ($self) = @_;
    return 0 unless -e $self->path;
    # Simple check with perl -cw
    my $path = $self->path;
    my $cmd = qq|perl -cw $path 2>&1|;
    my $rs = qx|$cmd|;

    ## File is ok if the returned string just contains "syntax OK"
    return 0 if $rs =~ /^$path syntax OK$/;

    chomp $rs;
    # Remove useless information
    $rs =~ s/\nBEGIN.*//;


    my @errors = split '\n', $rs;
    s/at .* line .*$// for @errors;
    s/.*syntax OK$// for @errors;

# added exception to 'Subroutine $FOO redefined' warnings
    s/^Subroutine .* redefined $// for @errors;

    # Remove "used only once: possible typo" known warnings
    # This is a temporary fix, waiting for a better fix on bug 16104
    s/^Name "Cache::RemovalStrategy::FIELDS" used only once: possible typo // for @errors;
    s/^Name "Cache::RemovalStrategy::LRU::FIELDS" used only once: possible typo // for @errors;
    s/^Name "Tie::Hash::FIELDS" used only once: possible typo // for @errors;

    @errors = grep {!/^$/} @errors;
    return \@errors;
}

sub check_forbidden_patterns {
    my ($self, $cnt) = @_;

    my @forbidden_patterns = (
        {pattern => qr{warn Data::Dumper::Dumper}, error => "Data::Dumper::Dumper"},
        {pattern => qr{<<<<<<<}, error => "merge marker (<<<<<<<)"},# git merge non terminated
        {pattern => qr{>>>>>>>}, error => "merge marker (>>>>>>>)"},
        {pattern => qr{=======}, error => "merge marker (=======)"},
        {pattern => qr{IFNULL}  , error => "IFNULL (must be replaced by COALESCE)"},  # COALESCE is preferable
        {pattern => qr{\t},     , error => "tab char"},
        {pattern => qr{ $},    , error => "trailing space char"},
        {pattern => qr{IndependantBranches}, error => "IndependantBranches is now known as IndependentBranches"},  # Bug 10080 renames IndependantBranches to IndependentBranches
        {pattern => qr{either version 2 of the License}, error => "Koha is now under the GPLv3 license"}, # see http://wiki.koha-community.org/wiki/Coding_Guidelines#Licence
        {pattern => qr{wthdrawn}, error => "wthdrawn should be replaced by withdrawn (see bug 10550)"},
        {pattern => qr{template_name\s*=>.*\.tmpl}, error => "You should not use a .tmpl extension for the template name (see bug 11349)"},
        {pattern => qr{sub type}, error => "Warning: The 'sub type' may be wrong is declared in a Koha::* package (see bug 15446)"},
        {pattern => qr{Koha::Branches}, error => "Koha::Branches has been removed by bug 15294"},
        {pattern => qr{Koha::Borrower}, error => "Koha::Borrower has been moved by bug 15548"},
        {pattern => qr{(^|\s)(h|H)e(\s|$)}, error => "Do not assume male gender, use they/them instead (bug 18432)"},
        {pattern => qr{(^|\s)(h|H)is(\s|$)}, error => "Do not assume male gender, use they/them instead (bug 18432)"},
    );
    push @forbidden_patterns, {pattern => qr{insert\s+into\s+`?systempreferences}i, error => "Use INSERT IGNORE INTO on inserting a new syspref (see bug 9071)"}
        if $self->filename eq 'updatedatabase.pl';

    return $self->SUPER::check_forbidden_patterns($cnt, \@forbidden_patterns);
}

sub check_pod {
    my ($self) = @_;
    return 0 unless -e $self->path;

    my $cmd = q{
        perl -e "use Pod::Checker;
        podchecker('} . $self->path . q{', \\*STDERR);"};

    my ( $success, $error_code, $full_buf, $stdout_buf, $stderr_buf ) =
      run( command => $cmd, verbose => 0 );

    # Encapsulate the potential errors
    my @errors;
    for my $line (@$full_buf) {
        chomp $line;

        $line =~ s/\(?at line \d+\)?//g;

        push @errors, $line;
    }

    return @errors
        ? \@errors
        : 0;
}

sub check_pod_coverage {
    my ($self) = @_;

    # If the module has been removed
    unless ( -e $self->path ) {
        return {
            rating => 1, subs => [],
        }
    }

    my $package_name = $self->path;
    $package_name =~ s|/|::|g;
    $package_name =~ s|\.pm$||;

    # Using Pod::Coverage from here will not work
    # the module will not be reloaded
    # Could be done with delete $INC{$self->path}, but get subroutine redefined warnings
    my $cmd = qq{
        perl -MPod::Coverage=$package_name -e666
    };

    my ( $success, $error_code, $full_buf, $stdout_buf, $stderr_buf ) =
      run( command => $cmd, verbose => 0 );

    my ( $rating, $subs ) = split '\\n', $stdout_buf->[0];
    if ( $rating =~ m|unrated| ) {
        $rating = 0;
    }
    $rating =~ s|^.*rating of ||;
    $subs =~ s|^The following are uncovered: ||;
    $subs =~ s| is uncovered$||;
    my @subs = split ', ', $subs;
    return { rating => $rating, subs => \@subs };
}

1;

__END__

=pod

=head1 NAME

QohA::File::Perl - Representation of a Perl file in QohA

=head1 DESCRIPTION

This module allow to launch several tests on a Perl file.
Tests are: perlcritic, perl -cw and if it does not contain a line with a forbidden pattern.

=head1 AUTHOR
Mason James <mtj at kohaaloha.com>
Jonathan Druart <jonathan.druart@biblibre.com>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by KohaAloha and BibLibre

This is free software, licensed under:

  The GNU General Public License, Version 3, June 2007
=cut
