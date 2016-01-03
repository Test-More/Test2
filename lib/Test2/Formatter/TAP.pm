package Test2::Formatter::TAP;
use strict;
use warnings;

use Test2::Util::HashBase qw{
    no_numbers no_header no_diag handles _encoding
};

sub OUT_STD()  { 0 }
sub OUT_ERR()  { 1 }
sub OUT_TODO() { 2 }

use Carp qw/croak/;

use base 'Test2::Formatter';

my %CONVERTERS = (
    'Test2::Event::Ok'        => '_ok_event',
    'Test2::Event::Skip'      => '_skip_event',
    'Test2::Event::Note'      => '_note_event',
    'Test2::Event::Diag'      => '_diag_event',
    'Test2::Event::Bail'      => '_bail_event',
    'Test2::Event::Exception' => '_exception_event',
    'Test2::Event::Subtest'   => '_subtest_event',
    'Test2::Event::Plan'      => '_plan_event',
);

sub register_event {
    my $class = shift;
    my ($type, $convert) = @_;
    croak "Event type is a required argument" unless $type;
    croak "Event type '$type' already registered" if $CONVERTERS{$type};
    croak "The second argument to register_event() must be a code reference"
        unless $convert && ref($convert) eq 'CODE';
    $CONVERTERS{$type} = $convert;
}

_autoflush(\*STDOUT);
_autoflush(\*STDERR);

sub init {
    my $self = shift;

    $self->{+HANDLES} ||= $self->_open_handles;
    if(my $enc = delete $self->{encoding}) {
        $self->encoding($enc);
    }
}

sub encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;
        my $handles = $self->{+HANDLES};

        # https://rt.perl.org/Public/Bug/Display.html?id=31923
        # If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
        # order to avoid the thread segfault.
        if ($enc =~ m/^utf-?8$/i) {
            binmode($_, ":utf8") for @$handles;
        }
        else {
            binmode($_, ":encoding($enc)") for @$handles;
        }
        $self->{+_ENCODING} = $enc;
    }

    return $self->{+_ENCODING};
}

if ($^C) {
    no warnings 'redefine';
    *write = sub {};
}
sub write {
    my ($self, $e, $num) = @_;

    my @tap = $self->event_tap($e, $num) or return;

    my $handles = $self->{+HANDLES};
    my $nesting = $e->nested || 0;
    my $indent = '    ' x $nesting;

    local($\, $", $,) = (undef, ' ', '');
    for my $set (@tap) {
        no warnings 'uninitialized';
        my ($hid, $msg) = @$set;
        next unless $msg;
        my $io = $handles->[$hid] or next;

        $msg =~ s/^/$indent/mg if $nesting;
        print $io $msg;
    }
}

sub _open_handles {
    my $self = shift;

    local $!;
    open( my $out, ">&STDOUT" ) or die "Can't dup STDOUT:  $!";
    open( my $err, ">&STDERR" ) or die "Can't dup STDERR:  $!";

    _autoflush($out);
    _autoflush($err);

    return [$out, $err, $out];
}

sub _autoflush {
    my($fh) = pop;
    my $old_fh = select $fh;
    $| = 1;
    select $old_fh;
}

sub event_tap {
    my $self = shift;
    my ($e, $num) = @_;

    my $converter = $CONVERTERS{ref($e)} or return;

    $num = undef if $self->{+NO_NUMBERS};

    return $self->$converter($e, $num);
}

sub _ok_event {
    my $self = shift;
    my ($e, $num) = @_;

    # We use direct hash access for performance. OK events are so common we
    # need this to be fast.
    my ($name, $todo) = @{$e}{qw/name todo/};
    my $in_todo = defined($todo);

    my $out = "";
    $out .= "not " unless $e->{pass};
    $out .= "ok";
    $out .= " $num" if defined $num;
    $out .= " - $name" if defined $name;
    $out .= " # TODO" if $in_todo;
    $out .= " $todo" if length $todo;

    # The primary line of TAP, if the test passed this is all we need.
    my @out = [OUT_STD, "$out\n"];
    return @out if $e->pass;

    #################
    # The rest of this is production of the diagnostics messages.
    #################

    # Figure out if the message goes to STDERR or to the TODO handle (typically STDOUT)
    # If the OK is either todo, or has the diag_todo set then this should go to
    # the TODO handle.
    my $diag_handle = (defined($todo) || $e->diag_todo) ? OUT_TODO : OUT_ERR;

    # This behavior is inherited from Test::Builder which injected a newline at
    # the start of the first diagnostics when the harness is active, but not
    # verbose. This is important to keep the diagnostics from showing up
    # appended to the existing line, which is hard to read. In a verbose
    # harness there is no need for this.
    my $prefix = $ENV{HARNESS_ACTIVE} && !$ENV{HARNESS_IS_VERBOSE} ? "\n" : "";

    # Figure out the debug info, this is typically the file name and line
    # number, but can also be a custom message. If no trace object is provided
    # then we have nothing useful to display.
    my $trace  = $e->trace;
    my $debug  = $trace ? $trace->debug : "[No trace info available]";

    # Create the initial diagnostics. If the test has a name we put the debug
    # info on a second line, this behavior is inherited from Test::Builder.
    my $msg = $in_todo ? "Failed (TODO)" : "Failed";
    $msg = defined($name)
        ? qq[$prefix# $msg test '$name'\n# $debug.\n]
        : qq[$prefix# $msg test $debug.\n];

    # Add the initial diagnostics line to the output list.
    push @out => [$diag_handle, $msg];

    # Sometimes additional diagnostics messages are associated with the Ok
    # object, we are going to display them as well.
    for my $diag (@{$e->diag || []}) {
        # Remove any trailing newlines, they are not consistently provided, and
        # we will add our own at the end.
        chomp(my $diag = $diag);

        # Add the '#' prefix to all lines, but skip the leading newlines.
        $diag = "# $diag" unless $diag =~ m/^\n/;
        $diag =~ s/\n/\n# /g;

        # Add the message to the output.
        push @out => [$diag_handle, "$diag\n"];
    }

    return @out;
}

sub _skip_event {
    my $self = shift;
    my ($e, $num) = @_;

    my $name   = $e->name;
    my $reason = $e->reason;
    my $todo   = $e->todo;

    my $out = "";
    $out .= "not " unless $e->{pass};
    $out .= "ok";
    $out .= " $num" if defined $num;
    $out .= " - $name" if $name;
    if (defined($todo)) {
        $out .= " # TODO & SKIP"
    }
    else {
        $out .= " # skip";
    }
    $out .= " $reason" if length $reason;

    return([OUT_STD, "$out\n"]);
}

sub _note_event {
    my $self = shift;
    my ($e, $num) = @_;

    chomp(my $msg = $e->message);
    $msg =~ s/^/# /;
    $msg =~ s/\n/\n# /g;

    return [OUT_STD, "$msg\n"];
}

sub _diag_event {
    my $self = shift;
    my ($e, $num) = @_;
    return if $self->{+NO_DIAG};

    chomp(my $msg = $e->message);
    $msg =~ s/^/# /;
    $msg =~ s/\n/\n# /g;

    return [
        ($e->todo || $e->diag_todo) ? OUT_TODO : OUT_ERR,
        "$msg\n",
    ];
}

sub _bail_event {
    my $self = shift;
    my ($e, $num) = @_;

    return if $e->nested;

    return [
        OUT_STD,
        "Bail out!  " . $e->reason . "\n",
    ];
}

sub _exception_event {
    my $self = shift;
    my ($e, $num) = @_;
    return [ OUT_ERR, $e->error ];
}

sub _subtest_event {
    my $self = shift;
    my ($e, $num) = @_;

    # A 'subtest' is a subclass of 'ok'. Let the code that renders 'ok' render
    # this event.
    my ($ok, @diag) = $self->_ok_event($e, $num);

    # If the subtest is not buffered then the sub-events have already been
    # rendered, we can go ahead and return.
    return ($ok, @diag) unless $e->buffered;

    # In a verbose harness we indent the diagnostics from the 'Ok' event since
    # they will appear inside the subtest braces. This helps readability. In a
    # non-verbose harness we do nto do this because it is less readable.
    if ($ENV{HARNESS_IS_VERBOSE}) {
        # index 0 is the filehandle, index 1 is the message we want to indent.
        $_->[1] =~ s/^(.*\S)$/    $1/mg for @diag;
    }

    # Add the trailing ' {' to the 'ok' line of TAP output.
    $ok->[1] =~ s/\n/ {\n/;

    # Render the sub-events, we use our own counter for these.
    my $count = 0;
    my @subs = map {
        # Bump the count for any event that inherits from Ok.
        $count++ if $_->isa('Test2::Event::Ok');

        # This indents all output lines generated for the sub-events.
        # index 0 is the filehandle, index 1 is the message we want to indent.
        map { $_->[1] =~ s/^(.*\S)$/    $1/mg; $_ } $self->event_tap($_, $count);
    } @{$e->subevents};

    return (
        $ok,                # opening ok - name {
        @diag,              #   diagnostics if the subtest failed
        @subs,              #   All the inner-event lines
        [OUT_STD(), "}\n"], # } (closing brace)
    );
}

sub _plan_event {
    my $self = shift;
    my ($e, $num) = @_;

    return if $self->{+NO_HEADER};

    my $directive = $e->directive;
    return if $directive && $directive eq 'NO PLAN';

    my $reason = $e->reason;
    $reason =~ s/\n/\n# /g if $reason;

    my $plan = "1.." . $e->max;
    if ($directive) {
        $plan .= " # $directive";
        $plan .= " $reason" if defined $reason;
    }

    return [OUT_STD, "$plan\n"];
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::TAP - Standard TAP formatter

=head1 EXPERIMENTAL RELEASE

This is an experimental release. Using this right now is not recommended.

=head1 DESCRIPTION

This is what takes events and turns them into TAP.

=head1 SYNOPSIS

    use Test2::Formatter::TAP;
    my $tap = Test2::Formatter::TAP->new();

    # Switch to utf8
    $tap->encoding('utf8');

    $tap->write($event, $number); # Output an event

=head1 EXPORTS

=over 4

=item OUT_STD

=item OUT_ERR

=item OUT_TODO

These are constants to identify filehandles. These constants are used by events
to direct text to the correct filehandle.

=back

=head1 METHODS

=over 4

=item $bool = $tap->no_numbers

=item $tap->set_no_numbers($bool)

Use to turn numbers on and off.

=item $bool = $tap->no_header($bool)

=item $tap->set_no_header($bool)

When true, the plan will not be rendered.

=item $bool = $tap->no_diag

=item $tap->set_no_diag($bool)

When true, diagnostics will not be rendered.

=item $arrayref = $tap->handles

=item $tap->set_handles(\@handles);

Can be used to get/set the filehandles. Indexes are identified by the
C<OUT_STD, OUT_ERR, OUT_TODO> constants.

=item $encoding = $tap->encoding

=item $tap->encoding($encoding)

Get or set the encoding. By default no encoding is set, the original settings
of STDOUT and STDERR are used.

This directly modifies the stored filehandles, it does not create new ones.

=item $tap->write($e, $num)

Write an event to the console.

=item Test2::Formatter::TAP->register_event($pkg, sub { ... });

In general custom events are not supported. There are however occasions where
you might want to write a custom event type that results in TAP output. In
order to do this you use the C<register_event()> class method.

    package My::Event;
    use Test2::Formatter::TAP qw/OUT_STD OUT_ERR/;

    use base 'Test2::Event';
    use Test2::Util::HashBase accessors => [qw/pass name diag note/];

    Test2::Formatter::TAP->register_event(
        __PACKAGE__,
        sub {
            my $self = shift;
            my ($e, $num) = @_;
            return (
                [OUT_STD, "ok $num - " . $e->name . "\n"],
                [OUT_ERR, "# " . $e->name . " " . $e->diag . "\n"],
                [OUT_STD, "# " . $e->name . " " . $e->note . "\n"],
            );
        }
    );

    1;

=back

=head1 SOURCE

The source code repository for Test2 can be found at
F<http://github.com/Test-More/Test2/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=item Kent Fredric E<lt>kentnl@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2015 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
