# Copyright (c) 2008 by Ricardo Signes and David A. Golden. All rights reserved.
# Licensed under terms of Perl itself (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License was distributed with this file or you may obtain a 
# copy of the License from http://dev.perl.org/licenses/

package Metabase::Report;
use 5.006;
use strict;
use warnings;
use Carp ();
use JSON ();
use base 'Metabase::Fact';

our $VERSION = '0.001';
$VERSION = eval $VERSION; # convert '1.23_45' to 1.2345

#--------------------------------------------------------------------------#
# abstract methods -- fatal
#--------------------------------------------------------------------------#

sub report_spec {
  my $self = shift;
  Carp::confess "report_spec() not implemented by " . ref $self;
}

sub set_creator_id {
  my ($self, $guid) = @_;

  $self->SUPER::set_creator_id($guid);

  for my $fact ($self->facts) {
    $fact->set_creator_id($guid);
  }
}

#--------------------------------------------------------------------------#
# alternate constructor methods
#--------------------------------------------------------------------------#

# adapted from Fact::new() -- must keep in sync
# content field is optional -- should other fields be optional at this
# stage?  Maybe we shouldn't let any fields be optional

# XXX should probably refactor arg_spec for Fact->new so we can reuse it
# and just make the content one optional.  -- dagolden, 2009-03-31 

sub open {
  my ($class, @args) = @_;
  
  my $args = $class->__validate_args(
    \@args,
    { 
      resource       => 1,
      # still optional so we can manipulate anonymous facts -- dagolden, 2009-05-12
      creator_id     => 0,
    }
  );

  $args->{content} ||= [];

  # create and check
  my $self = $class->_init_guts($args);

  return $self;
}

sub add {
  my ($self, @args) = @_;
  Carp::confess("report is already closed") if $self->{__closed};

  my ($fact, $fact_class, $content );
  
  if ( @args == 1 && $args[0]->isa('Metabase::Fact') ) {
    $fact = $args[0];
  }
  else {
    ($fact_class, $content) = @args;
    $fact = $fact_class->new( 
      resource => $self->resource, 
      content  => $content,
    );
  }

  $fact->set_creator_id($self->creator_id) if $self->creator_id;

  push @{$self->{content}}, $fact;
  return $self;
}

# close just validates -- otherwise unnecessary
sub close {
  my ($self) = @_;
  my $class = ref $self;

  my $ok = eval { $self->validate_content; 1 };
  unless ($ok) {
    my $error = $@ || '(unknown error)';
    Carp::confess( "$class object content invalid: $error" );
  }

  $self->{__closed} = 1;

  return $self;
}

# accessor for facts -- this must work regardless of __closed so 
# that facts can be added using content_meta of facts already added
sub facts {
  my ($self) = @_;
  return @{ $self->content };
}

#--------------------------------------------------------------------------#
# implement required abstract Fact methods
#--------------------------------------------------------------------------#

sub from_struct {
  my ($class, $struct) = @_;
  my $self = $class->SUPER::from_struct($struct);
  $self->{__closed} = 1;
  return $self;
}

sub content_as_bytes { 
  my $self = shift;

  Carp::confess("can't serialize an open report") unless $self->{__closed};

  my $content = [ map { $_->as_struct } @{ $self->content } ];
  JSON->new->encode( $content );
}

sub content_from_bytes { 
  my ($self, $string) = @_;
  $string = $$string if ref $string;

  my $fact_structs = JSON->new->decode( $string );

  my @facts;
  for my $struct (@$fact_structs) {
    my $class = $self->class_from_type( $struct->{metadata}{core}{type}[1] );
    my $fact = eval { $class->from_struct($struct) }
      or Carp::confess "Unable to create a '$class' object: $@";
    push @facts, $fact;
  }

  return \@facts;
}

# XXX what if spec is '0' (not '0+')?  -- dagolden, 2009-03-30 
sub validate_content {
  my ($self) = @_;

  my $spec    = $self->report_spec;
  my $content = $self->content;

  die ref $self . " content must be an array reference of Fact object"
    unless ref $content eq 'ARRAY';

  my @fact_matched;
  # check that each spec matches
  for my $k ( keys %$spec ) {
    $spec->{$k} =~ m{^(\d+)(\+)?$};
    my $minimum = defined $1 ? $1 : 0;
    my $exact   = defined $2 ?  0 : 1; # exact unless "+"
    # mark facts that match a spec
    my $found = 0;
    for my $i ( 0 .. @$content - 1 ) {
      if ( $content->[$i]->isa( $k ) ) {
        $found++;
        $fact_matched[$i] = 1;
      }
    }
    if ( $exact ) {
      die "expected $minimum of $k, but found $found\n"
      if $found != $minimum;
    }
    else {
      die "expected at least $minimum of $k, but found $found\n"
      if $found < $minimum;
    }
  }

  # any facts that didn't match anything?
  my $unmatched = grep { ! $_ } @fact_matched;
  die "$unmatched fact(s) not in the spec\n" 
  if $unmatched;

  return;
}

#--------------------------------------------------------------------------#
# class methods
#--------------------------------------------------------------------------#

sub fact_classes {
  my ($self) = @_;
  my $class = ref $self || $self;
  return keys %{ $self->report_spec }
}

sub load_fact_classes {
  my ($self) = @_;
  for my $f ( $self->fact_classes ) {
    eval "require $f; 1" or Carp::confess "Could not load '$f': $@";
  }
  return;
}

1;

__END__

=head1 NAME

Metabase::Report - a base class for collections of Metabase facts

=head1 SYNOPSIS

  package MyReport;

  use base 'Metabase::Report';
  __PACKAGE__->load_fact_classes;

  sub report_spec {
    return {
      Fact::One => 1,     # one of Fact::One
      Fact::Two => "0+",  # zero or more of Fact::Two
    }
  }

=head1 DESCRIPTION

L<Metabase|Metabase> is a system for associating metadata with CPAN
distributions.  The metabase can be used to store test reports, reviews,
coverage analysis reports, reports on static analysis of coding style, or
anything else for which datatypes are constructed.

Metabase::Report is a base class for collections of Metabase::Fact
objects that can be sent to or retrieved from a Metabase system.

Metabase::Report is itself a subclass of Metabase::Fact and 
offers the same API, except as described below.

=head1 USAGE

[Talk about how to subclass...]

=head1 ATTRIBUTES

=head3 content

The 'content' attribute of a Report must be a reference to an array of 
Metabase::Fact subclass objects.

=head1 METHODS

In addition to the standard C<new()> constructor, the following C<open()>,
C<add()> and C<close()> methods may be used to construct a report piecemeal,
instead.

=head2 open()

  $report = Report::Subclass->open(
    id => 'AUTHORID/Foo-Bar-1.23.tar.gz',
  );

Constructs a new, empty report. The 'id' attribute is required.  The
'refers_to' attribute is optional.  The 'content' attribute may be provided,
but see C<add()> below. No other attributes may be provided to new().

=head2 add()

  $report->add( 'Fact::Subclass' => $content );

Using the 'id' attribute of the report, this method constructs a new Fact from
a class and a content argument.  The resulting Fact is appended to the Report's
content array.

=head2 close()

  $report->close;

This method validates the report based on all Facts added so far.

=head1 CLASS METHODS

=head2 fact_classes()

=head2 load_fact_classes()

Loads each class listed in the report spec.

=head1 ABSTRACT METHODS

Methods marked as 'required' must be implemented by a report subclass.  (The
version in Metabase::Report will die with an error if called.)  

In the documentation below, the terms 'must, 'must not', 'should', etc. have
their usual RFC meanings.

Methods MUST throw an exception if an error occurs.

=head2 report_spec() (required)

  $spec = Report::Subclass->report_spec;

The C<report_spec> method MUST return a hash reference that defines how
many Facts of which types must be in the report for it to be considered valid.
Keys MUST be class names.  Values MUST be non-negative integers that indicate
the number of Facts of that type that must be present for a report to be
valid, optionally followed by a '+' character to indicate that the report
may contain more than the given number.

For example:

  {
    Fact::One => 1,     # one of Fact::One
    Fact::Two => "0+",  # zero or more of Fact::Two
  }

=head1 BUGS

Please report any bugs or feature using the CPAN Request Tracker.  
Bugs can be submitted through the web interface at 
L<http://rt.cpan.org/Dist/Display.html?Queue=CPAN-Metabase-Fact>

When submitting a bug or request, please include a test-file or a patch to an
existing test-file that illustrates the bug or desired feature.

=head1 AUTHOR

=over 

=item * David A. Golden (DAGOLDEN)

=item * Ricardo J. B. Signes (RJBS)

=back

=head1 COPYRIGHT AND LICENSE

 Portions copyright (c) 2008 by David A. Golden
 Portions copyright (c) 2008 by Ricardo J. B. Signes

Licensed under the same terms as Perl itself (the "License").
You may not use this file except in compliance with the License.
A copy of the License was distributed with this file or you may obtain a 
copy of the License from http://dev.perl.org/licenses/

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

