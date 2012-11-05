package Dist::Zilla::Plugin::Rinci::Validate;

use 5.010;
use strict;
use warnings;

use Data::Sah;
use Perinci::Access::InProcess;

my $sah = Data::Sah->new;
my $plc = $sah->get_compiler("perl");
my $pa  = Perinci::Access::InProcess->new(load=>0);

# VERSION

use Moose;
with (
	'Dist::Zilla::Role::FileMunger',
	'Dist::Zilla::Role::FileFinderUser' => {
		default_finders => [ ':InstallModules' ],
	},
);

use PPI;
use namespace::autoclean;

sub munge_files {
	my $self = shift;

	$self->munge_file($_) for @{ $self->found_files };
	return;
}

sub munge_file {
	my ( $self, $file ) = @_;

	if ( $file->name =~ m/\.pod$/ixms ) {
		$self->log_debug( 'Skipping: "' . $file->name . '" is pod only');
		return;
	}

	my $version = $self->zilla->version;

	my $content = $file->content;

	my $doc = PPI::Document->new(\$content)
		or $self->log( 'Skipping: "'
			. $file->name
			.  '" error with PPI: '
			. PPI::Document->errstr
			)
			;

	return unless defined $doc;

	my $comments = $doc->find('PPI::Token::Comment');

	my $validate_regex
            = q{
                  ^
                  (\s*)           # capture all whitespace before comment
                  (
                    \#\s+VERSION  # capture # VERSION
                    \b            # and ensure it ends on a word boundary
                    [             # conditionally
                      [:print:]   # all printable characters after VERSION
                      \s          # any whitespace including newlines see GH #5
                    ]*            # as many of the above as there are
                  )
                  $               # until the EOL}
		;

	my $munged_version = 0;
	if ( ref($comments) eq 'ARRAY' ) {
		foreach ( @{ $comments } ) {
			if ( /$version_regex/xms ) {
				my ( $ws, $comment ) =  ( $1, $2 );
				$comment =~ s/(?=\bVERSION\b)/TRIAL /x if $self->zilla->is_trial;
				my $code
						= "$ws"
						. q{our $VERSION = '}
						. $version
						. qq{'; $comment}
						;
				$_->set_content("$code");
				$file->content( $doc->serialize );
				$munged_version++;
			}
		}
	}

	if ( $munged_version ) {
		$self->log_debug([ 'adding $VERSION assignment to %s', $file->name ]);
	}
	return;
}
__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Insert argument validator code in output code

=head1 SYNOPSIS

in dist.ini

 [Rinci::Validate]

in your modules

 $SPEC{foo} = {
     args => {
         arg1 => { schema => ['int*', default=>3] },
         arg2 => { },
     },
 };
 sub foo {
     my %args = @_;

     my $arg1 = $args{arg1}; # VALIDATE_ARG
     ...
 }

output will be something like:

 $SPEC{foo} = {
     args => {
         arg1 => { schema => ['int*', default=>3] },
         arg2 => { },
     },
 };
 sub foo {
     my %args = @_;

     my $arg1 = $args{arg1}; require Scalar::Util; my $err_arg1; (($arg1 //= 3), 1) && ((defined($arg1)) ? 1 : (($err_arg1 = 'TMPERRMSG: required data not specified'),0)) && ((Scalar::Util::looks_like_number($arg1) =~ /^(?:1|2|9|10|4352)$/) ? 1 : (($err_arg1 = 'TMPERRMSG: type check failed'),0)); return [400, "Invalid value for arg1: $err_arg1"] if $arg1; # VALIDATE_ARG
     ...
 }

=head1 DESCRIPTION

This module can be used as an alternative to L<Perinci::Sub::Wrapper>, at least
when it comes to validating arguments.

If you use Perinci::Sub::Wrapper, function needs to be wrapped first before
argument validation (including setting default value) can work. If you use this
module, function needs not be wrapped (but on the other hand, you have to
build/install the distribution first for the validation code to be munged into
source code).

If you use this module, it is recommended that you also put C<<
_perinci.sub.wrapper.validate_args => 0 >> attribute into your function
metadata, to instruct Perinci::Sub::Wrapper to skip generating argument
validation code when wrapping the function, as argument validation is already
done.


=head2 USAGE

 my $arg1 = $arguments{arg1}; # VALIDATE_ARG

The significant part that is interpreted by this module is C<my $arg1>. Argument
name is taken from the name of the lexical variable (in this case, C<arg1>).
Argument must be specified in the metadata. If argument name is different, then
you need to say:

 my $f = $args->{frobniciate}; # VALIDATE_ARG frobnicate

You can also choose to just say:

 my $arg1; # VALIDATE_ARG

To validate all arguments in the schema, you can say:

 sub foo {
     my %args = @_; # VALIDATE_ARGS

There should only be one VALIDATE_ARGS per subroutine.


=head1 FAQ

=head2 Rationale?

Embedding validation code directly in the source code during building, instead
of compiling them during runtime, reduces startup overhead.

As for the rationale for using L<Rinci> metadata or L<Sah> schemas at all,
please read their respective documentation.

=head2 But it looks ugly!

Admittedly, yes. Validation source code is put in a single long line to avoid
modifying line numbers. An option to not compress everything as a single line
might be added in the future.


=head1 TODO

=over

=item * Use L<PPI> instead of naive regex.

=item * Option to not compress validator code to a single line.

=back

=cut
