package Dist::Zilla::Plugin::Rinci::Validate;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Data::Sah;
use Perinci::Access::InProcess;

my $sah = Data::Sah->new();
my $plc = $sah->get_compiler("perl");
$plc->indent_character('');
my $pa  = Perinci::Access::InProcess->new(load=>0, cache_size=>0);

# VERSION

use Moose;
use namespace::autoclean;

with (
    'Dist::Zilla::Role::FileMunger',
    'Dist::Zilla::Role::FileFinderUser' => {
        default_finders => [':InstallModules'],
    },
);

sub __squish_code {
    my $code = shift;
    for ($code) {
        s/^\s*#.+//mg; # comment line
        s/^\s+//mg;    # indentation
        s/\n+/ /g;     # newline
    }
    $code;
}

sub munge_files {
    my $self = shift;

    $self->munge_file($_) for @{ $self->found_files };
    return;
}

sub munge_file {
    my ($self, $file) = @_;

    my $fname = $file->name;
    $log->tracef("Processing file %s ...", $fname);

    unless ($fname =~ m!lib/(.+\.pm)$!) {
        #$self->log_debug("Skipping: '$fname' not a module");
        return;
    }
    my $reqname = $1;

    # i do it this way (unshift @INC, "lib" + require "Foo/Bar.pm" instead of
    # unshift @INC, "." + require "lib/Foo/Bar.pm") in my all other Dist::Zilla
    # and Pod::Weaver plugin, so they can work together (require "Foo/Bar.pm"
    # and require "lib/Foo/Bar.pm" would cause Perl to load the same file twice
    # and generate redefine warnings).

    local @INC = ("lib", @INC);

    eval { require $reqname };
    if ($@) {
        $self->log_fatal("$fname: has compile errors: $@");
        return;
    }

    my @content = split /^/, $file->content;
    my $munged;
    my $in_pod;
    my ($pkg_name, $sub_name, $metas, $meta, $arg, $var);
    my $sub_has_vargs; # VALIDATED_ARGS has been declared for the sub
    my %vargs; # list of validated args for current sub
    my %vsubs; # list of subs
    my $i = 0; # line number

    my $check_prev_sub = sub {
        return unless $sub_name;
        return unless $meta;
        return unless $meta->{args};
        my %unvalidated;
        for (keys %{ $meta->{args} }) {
            $unvalidated{$_}++ unless $vargs{$_};
        }
        if (keys %unvalidated) {
            $self->log("NOTICE: $fname: Some argument(s) not validated ".
                           "for sub $sub_name: ".join(", ", keys %unvalidated));
        }
    };

    my $gen_err = sub {
        my ($status, $msg, $cond) = @_;
        if ($meta->{result_naked}) {
            return qq[if ($cond) { die $msg } ];
        } else {
            return qq|if ($cond) { return [$status, $msg] } |;
        }
    };
    my $gen_merr = sub {
        my ($cond, $arg) = @_;
        $gen_err->(400, qq["Missing argument: $arg"], $cond);
    };
    my $gen_verr = sub {
        my ($cond, $arg) = @_;
        $gen_err->(400, qq["Invalid argument value for $arg: \$arg_err"],
                   $cond);
    };

    my $gen_arg = sub {
        my $meta = $metas->{$sub_name};
        my $cd = $plc->compile(
            schema      => $meta->{args}{$arg}{schema},
            err_term    => '$arg_err',
            data_name   => $arg,
            data_term   => $var,
            return_type => 'str',
            comment     => 0,
        );
        my @code;
        push @code, 'my $arg_err; ' unless keys %vargs;
        push @code, __squish_code($cd->{result}), "; ";
        push @code, $gen_verr->('$arg_err', $arg);
        $vargs{$arg}++;
        join "", @code;
    };

    my $gen_args = sub {
        my @code;
        for my $arg (keys %{ $meta->{args} }) {
            my $as = $meta->{args}{$arg};
            my $kvar; # var to access a hash key
            $kvar = $var; $kvar =~ s/.//;
            $kvar = join(
                "",
                "\$$kvar",
                (($meta->{args_as} // "hash") eq "hashref" ? "->" : ""),
                "{'$arg'}",
            );
            if ($as->{req}) {
                push @code, $gen_merr->("!exists($kvar)", $arg);
            }
            my $s = $meta->{args}{$arg}{schema};
            if ($s) {
                my $cd = $plc->compile(
                    schema      => $s,
                    err_term    => '$arg_err',
                    data_name   => $arg,
                    data_term   => $kvar,
                    return_type => 'str',
                    comment     => 0,
                );
                push @code, 'my $arg_err; ' unless keys %vargs;
                $vargs{$arg}++;
                push @code, __squish_code($cd->{result}), "; ";
                push @code, $gen_verr->('$arg_err', $arg);
            }
        }
        join "", @code;
    };

    for (@content) {
        $i++;
        #$log->tracef("Line $i: %s", $_);
        if (/^=cut\b/x) {
            $in_pod = 0;
            next;
        }
        next if $in_pod;
        if (/^=\w+/x) {
            $in_pod++;
            next;
        }
        if (/^\s*package \s+ (\w+(?:::\w+)*)/x) {
            $pkg_name = $1;
            $log->tracef("Found package declaration %s", $pkg_name);
            my $uri = "/$pkg_name/"; $uri =~ s!::!/!g;
            my $res = $pa->request(child_metas => $uri);
            unless ($res->[0] == 200) {
                $self->log_fatal(
                    "$fname: can't child_metas => $uri: ".
                        "$res->[0] - $res->[2]");
                return;
            }
            $metas = {};
            for (keys %{$res->[2]}) {
                next unless m!.+/(\w+)$!;
                $metas->{$1} = $res->[2]{$_};
            }
            next;
        }
        if (/^\s*sub \s+ (\w+)/x) {
            $log->tracef("Found sub declaration %s", $1);
            unless ($pkg_name) {
                $self->log_fatal(
                    "$fname:$i: sub without package definition");
                next;
            }
            $check_prev_sub->();
            $sub_name      = $1;
            $sub_has_vargs = 0;
            %vargs         = ();
            $meta          = $metas->{$sub_name};
            next;
        }
        if (/^
             (?<code>\s* my \s+ (?<sigil>[\$@%]) (?<var>\w+) \b .+)
             (?<tag>\#\s*VALIDATE_ARG(?<s> S)? (?: \s+ (?<var2>\w+))? \s*$)/x) {
            $log->tracef("Found line with tag %s", $_);
            my %m = %+;
            $arg = $m{var2} // $m{var};
            $var = $m{sigil} . $m{var};
            unless ($sub_name) {
                $self->log(
                    "$fname:$i: # VALIDATE_ARG(S?) outside sub");
                next;
            }
            unless ($meta) {
                $self->log_fatal(
                    "$fname:$i: # VALIDATE_ARG(S?) ".
                        "but no metadata for sub $sub_name");
                next;
            }
            if (($meta->{v} // 1.0) != 1.1) {
                $self->log_fatal(
                    "$fname:$i: # VALIDATE_ARG(S?) but ".
                        "metadata is not v1.1 (only v1.1 is supported)");
                next;
            }
            if (($meta->{args_as} // "hash") !~ /^hash(ref)?$/) {
                $self->log_fatal(
                    "$fname:$i: # VALIDATE_ARG(S?) for sub $sub_name: ".
                        "Sorry, only args_as=hash/hashref currently supported");
                next;
            }
            if (($meta->{v} // 1.0) != 1.1) {
                $self->log_fatal(
                    "$fname:$i: # VALIDATE_ARG(S?) but ".
                        "metadata does not have args definition");
                next;
            }
            if ($m{s} && $sub_has_vargs) {
                $self->log_fatal(
                    "$fname:$i: multiple # VALIDATE_ARGS for sub $sub_name");
                next;
            }
            if (!$m{s}) {
                unless ($meta->{args}{$arg} && $meta->{args}{$arg}{schema}) {
                    $self->log_fatal(
                        "$fname:$i: # VALIDATE_ARG for ".
                            "no schema for argument $arg");
                    next;
                }
            }
            if ($m{s} && $m{sigil} ne '%') {
                $self->log_fatal(
                    "$fname:$i: invalid variable $var ".
                        "for # VALIDATE_ARGS, must be hash");
                next;
            }
            if (!$m{s} && $m{sigil} ne '$') {
                $self->log_fatal(
                    "$fname:$i: invalid variable $var ".
                        "for # VALIDATE_ARG, must be scalar");
                next;
            }

            $munged++;
            $log->tracef("Munging ...");
            if ($m{s}) {
                $_ = $m{code} . $gen_args->() . "" . $m{tag};
            } else {
                $_ = $m{code} . $gen_arg->() . "" . $m{tag};
            }
        }
    }
    $check_prev_sub->();

    if ($munged) {
        $self->log("Adding argument validation code for $fname");
        $file->content(join "", @content);
    }

    return;
}

__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Insert argument validator code in output code

=head1 SYNOPSIS

In dist.ini:

 [Rinci::Validate]

In your module:

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

     my $arg1 = $args{arg1}; require Scalar::Util; my $arg_err; (($arg1 //= 3), 1) && ((defined($arg1)) ? 1 : (($err_arg1 = 'TMPERRMSG: required data not specified'),0)) && ((Scalar::Util::looks_like_number($arg1) =~ /^(?:1|2|9|10|4352)$/) ? 1 : (($err_arg1 = 'TMPERRMSG: type check failed'),0)); return [400, "Invalid value for arg1: $err_arg1"] if $arg1; # VALIDATE_ARG
     ...
 }


=head1 DESCRIPTION

This plugin inserts argument validation code into your module source code, at
location marked with C<# VALIDATE_ARG> or C<# VALIDATE_ARGS>. Validation code is
compiled using C<Data::Sah> from Sah schemas specified in C<args> property in
C<Rinci> function metadata in the module.


=head2 USAGE

To validate a single argument, in your module:

 sub foo {
     my %args = @_;
     my $arg1 = $args{arg1}; # VALIDATE_ARG

The significant part that is interpreted by this module is C<my $arg1>. Argument
name is taken from the lexical variable's name (in this case, C<arg1>). Argument
must be defined in the C<args> property of the function metadata. If argument
name is different from lexical variable name, then you need to say:

 my $f = $args->{frobnicate}; # VALIDATE_ARG frobnicate

To validate all arguments of the subroutine, you can say:

 sub foo {
     my %args = @_; # VALIDATE_ARGS

There should only be one VALIDATE_ARGS per subroutine.

If you use this plugin, and you plan to wrap your functions too using
L<Perinci::Sub::Wrapper> (or through L<Perinci::Access>, L<Perinci::CmdLine>,
etc), you might also want to put C<< _perinci.sub.wrapper.validate_args => 0 >>
attribute into your function metadata, to instruct Perinci::Sub::Wrapper to skip
generating argument validation code when your function is wrapped, as argument
validation is already done by the generated code.


=head1 FAQ

=head2 Rationale for this plugin?

This plugin is an alternative to L<Perinci::Sub::Wrapper>, at least when it
comes to validating arguments. Perinci::Sub::Wrapper can also generate argument
validation code (among other things), but it is done during runtime and can add
to startup overhead (compiling complex schemas for several subroutines can take
up to 100ms or more, on my laptop). Using this plugin, argument validation code
is generated during building of your distribution.

Using this plugin also makes sure that argument is validated whether your
subroutine is wrapped or not. Using this plugin also avoids wrapping and adding
nest level, if that is not to your liking.

Instead of using this plugin, you can use wrapping either by using
L<Perinci::Exporter> or by calling Perinci::Sub::Wrapper's C<wrap_sub> directly.

=head2 But why use Rinci metadata or Sah schema?

In short, adding Rinci metadata to your subroutines allows various tools to do
useful stuffs, relieving you from doing those stuffs manually. Using Sah schema
allows you to write validation code succintly, and gives you the ability to
automatically generate Perl/JavaScript/error messages from the schema.

See their respective documentation for more details.


=head2 But the generated code looks ugly!

Admittedly, yes. Validation source code is formatted as a single long line to
avoid modifying line numbers, which is desirable when debugging your modules. An
option to not compress everything as a single line might be added in the future.


=head1 TODO

=over

=item * Use L<PPI> instead of fragile regex.

=item * Option to not compress validator code to a single line.

=item * Option to configure variable name to store validation (C<$arg_err>).

=back

=cut
