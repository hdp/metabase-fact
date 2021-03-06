# Copyright (c) 2008 by Ricardo Signes. All rights reserved.
# Licensed under terms of Perl itself (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License was distributed with this file or you may obtain a 
# copy of the License from http://dev.perl.org/licenses/

package Metabase::Fact;
use 5.006;
use strict;
use warnings;
use Data::GUID guid_string => { -as => '_guid' };
use Carp ();

our $VERSION = '0.001';
$VERSION = eval $VERSION; # convert '1.23_45' to 1.2345

#--------------------------------------------------------------------------#
# main API methods -- shouldn't be overridden
#--------------------------------------------------------------------------#

# We originally used Params::Validate, but only for
# required/optional/disallowed, and it was Yet Another Prereq for what
# needed to be a very small set of libraries.  Sadly, we've rolled our
# own... -- rjbs, 2009-03-30
sub __validate_args {
  my ($self, $args, $spec) = @_;
  my $hash = (@$args == 1 and ref $args->[0]) ? { %{ $args->[0]  } }
           : (@$args == 0)                    ? { }
           :                                    { @$args };
  
  my @errors;

  for my $key (keys %$hash) {
    push @errors, qq{unknown argument "$key" when constructing $self}
      unless exists $spec->{ $key };
  }

  for my $key (grep { $spec->{ $_ } } keys %$spec) {
    push @errors, qq{missing required argument "$key" when constructing $self}
      unless defined $hash->{ $key };
  }

  Carp::confess(join qq{\n}, @errors) if @errors;

  return $hash;
}

sub new {
    my ($class, @args) = @_;
    my $args = $class->__validate_args(
      \@args,
      { 
        content        => 1,
        resource       => 1,  # where to validate? -- dagolden, 2009-03-31
        # still optional so we can manipulate anonymous facts -- dagolden, 2009-05-12
        creator_id     => 0,
      },
    );

    my $self = $class->_init_guts($args);

    # XXX rename to validate -- dagolden, 2009-03-31
    eval { $self->validate_content };
    if ($@) {
        Carp::confess( "$class object content invalid: $@" );
    }

    return $self;
}

sub _init_guts {
  my ($class, $args) = @_;
  my $self = bless {}, $class;

  $args->{schema_version} = $self->default_schema_version
    unless defined $args->{schema_version};

  $args->{type} = $self->type
    unless defined $args->{type};

  $self->upgrade_fact($args)
    if  $args->{schema_version} != $self->default_schema_version;

  Carp::confess("illegal type ($args->{type}) for $self")
    if $args->{type} ne $self->type;

  my $meta = $self->{metadata} = { core => {} };
  $self->{content} = $args->{content};

  # XXX I hate seeing ...[1] everywhere for metadata -- dagolden, 2009-03-31 
  $meta->{core}{created_at}     = [ Num => $args->{created_at} || time  ];
  $meta->{core}{guid}           = [ Str => $args->{guid}       || _guid ];
  $meta->{core}{resource}       = [ Str => $args->{resource}            ];
  $meta->{core}{schema_version} = [ Num => $args->{schema_version}      ];
  $meta->{core}{type}           = [ Str => $self->type                  ];

  if (defined $args->{creator_id}) {
    $meta->{core}{creator_id}   = [ Str => $args->{creator_id}          ];
  }

  return $self;
}

sub created_at       { $_[0]->{metadata}{core}{created_at}[1]     }
sub content          { $_[0]->{content}                           }
sub guid             { $_[0]->{metadata}{core}{guid}[1]           }
sub resource         { $_[0]->{metadata}{core}{resource}[1]       }
sub schema_version   { $_[0]->{metadata}{core}{schema_version}[1] }

sub creator_id       {
  my ($self) = @_;
  return unless my $creator_id_datum = $_[0]->{metadata}{core}{creator_id};
  return $creator_id_datum->[1];
}

sub set_creator_id {
  my ($self, $guid) = @_;

  Carp::confess("can't set creator_id; it is already set")
    if $self->creator_id;

  $self->{metadata}{core}{creator_id} = [ Str => $guid ];
}
  
sub as_struct {
    my ($self) = @_;

    return {
      content  => $self->content_as_bytes,
      metadata => {
        core => $self->core_metadata,
      }
    };
}

sub from_struct {
  my ($class, $struct) = @_;
  my $metadata  = $struct->{metadata};
  my $core_meta = $metadata->{core};

  Carp::confess("invalid fact type: $core_meta->{type}[1]")
    unless $class->type eq $core_meta->{type}[1];

  # transfrom struct into content and core metadata arguments the way they
  # would be given to new(), then validate these and get an object from _init_guts()
  my @args = ( 
    (map { $_ => $core_meta->{$_}[1] } keys %$core_meta),
    content  => $class->content_from_bytes($struct->{content}),
  );
  my $args = $class->__validate_args(
    \@args,
    { 
      # when thawing, all of these must be provided
      content        => 1,
      created_at     => 1,
      guid           => 1,
      resource       => 1,
      schema_version => 1,
      type           => 1,
      # still optional so we can manipulate anonymous facts -- dagolden, 2009-05-12
      creator_id     => 0, 
    },
  );
  my $self = $class->_init_guts($args);

  # if metadata from resource or content were included in struct, add them
  # back to the object
  $self->{metadata}{resource} = $metadata->{resource} if $metadata->{resource};
  $self->{metadata}{content}  = $metadata->{content}  if $metadata->{content};

  return $self;
}

sub resource_metadata {
    my $self = shift;

    return $self->{metadata}{resource} ||= {};
}

sub core_metadata {
    my $self = shift;
    $self->{metadata}{core};
}

#--------------------------------------------------------------------------#
# utilities for all facts to do class/type conversions
#--------------------------------------------------------------------------#

# type_from_class
sub type {
  my $self = shift;
  my $type = ref $self || $self;

  $type =~ s{::}{-}g;
  return $type;
}

# XXX: I'm not really excited about having this in here. -- rjbs, 2009-03-28
# XXX: Need it type() for symmetry.  Make it private? -- dagolden, 2009-03-31
sub class_from_type {
    my (undef, $type) = @_;
    $type =~ s/-/::/g;
    return $type;
}

#--------------------------------------------------------------------------#
# class methods
#--------------------------------------------------------------------------#

# schema_version recorded in 'version' attribution during new()
# if format of content changes, class module should increment schema version
# to check: if ( $obj->version != $class->schema_version ) ...

# XXX should this be a fatal abstract?  Forcing classes to be
# explicit about schema versions? Annoying, but correct -- dagolden, 2009-03-31
sub default_schema_version() { 1 }

#--------------------------------------------------------------------------#
# abstract methods -- mostly fatal
#--------------------------------------------------------------------------#

sub content_metadata { return }

sub upgrade_fact {
    my ($self) = @_;
    Carp::confess "Detected a schema mismatch, but upgrade_fact() not implemented by "
      . (ref $self || $self)
}

sub content_as_bytes {
    my ($self, $content) = @_;
    Carp::confess "content_as_bytes() not implemented by "
      . (ref $self || $self)
}

sub content_from_bytes {
    my ($self, $bytes) = @_;
    Carp::confess "content_from_bytes() not implemented by "
      . (ref $self || $self)
}

# XXX rename to validate -- dagolden, 2009-03-31 
sub validate_content {
    my ($self, $content) = @_;
    Carp::confess "validate_content() not implemented by "
      . (ref $self || $self)
}

1;

__END__

=head1 NAME

Metabase::Fact - base class for Metabase Facts

=head1 SYNOPSIS

  # defining the fact class
  package MyFact;
  use base 'Metabase::Fact';

  sub content_as_bytes {
    ...
  }

  sub content_from_bytes {
    ...
  }

  sub content_metadata {
    ...
  }

  sub validate_content {
    ...
  }

  sub upgrade_fact {
    ...
  }

  # using the fact class
  my $fact = TestReport->new(
    resource => 'RJBS/CPAN-Metabase-Fact-0.001.tar.gz',
    content     => {
      status => 'FAIL',
      time   => 3029,
    },
  );

  $client->send_fact($fact);


=head1 DESCRIPTION

L<Metabase> is a framework for associating metadata with arbitrary
resources.  A Metabase can be used to store test reports, reviews, coverage
analysis reports, reports on static analysis of coding style, or anything else
for which datatypes are constructed.

Metabase::Fact is a base class for facts (really opinions or analyses)
that can be sent to or retrieved from a Metabase system.

=head1 USAGE

[Talk about how to subclass...]

=head1 ATTRIBUTES

Unless otherwise noted, all attributes are read-only and are either provided as 
arguments to the constructor or are generated during construction.

=head2 Arguments provided to C<new()>

=head3 resource (required)

The canonical resource (URI) the Fact relates to.  For CPAN distributions, this
would be a C<cpan:///distfile/> URL.  (See L<URI::cpan>.)

=head3 content (required)

A reference to the actual information associated with the fact.
The exact form of the content is up to each Fact class to determine.

=head3 creator_id (optional)

A L<Metabase::User::Profile> URI that indicates the creator of the Fact.  This
is normally set by the Metabase when a Fact is submitted based on the
submitter's Profile, but can be set during construction if the creator and
submitter are not the same person.  The C<set_creator_id> mutator may be called
to set C<creator_id>, but only if it is not previously set.

=head2 Generated during construction

These attributes are generated automatically during the call to C<new()>.

=head3 guid

The Fact object's Globally Unique IDentifier.

=head3 schema_version

The schema_version() of the Fact subclass that created the object. This may or
may not be the same as the current schema_version() of the class if newer
versions of the class have been released since the object was created.

=head3 created_at

Fact creation time in epoch seconds.

=head1 METHODS

=head2 new()

  $fact = myfact->new(
    resource => 'AUTHORID/Foo-Bar-1.23.tar.gz',
    content => $content_structure,
  );

Constructs a new Fact. The 'resource' and 'content' attributes are required.  No
other attributes may be provided to new() except 'creator_id'.

=head1 CLASS METHODS

=head2 default_schema_version()

  $version = Fact::Subclass->default_schema_version;

Defaults to 1.  Subclasses should override this method if they make a
backwards-incompatible change to the internals of the content attribute.
Schema version numbers should be monotonically-increasing integers.  The 
default schema version is used to set an objects schema_version attribution
on creation.

=head2 type()

  $type = Fact::Subclass->type;

The class name, with double-colons converted to dashes to be more
URI-friendly.  E.g.  'Metabase::Fact' would be 'Metabase-Fact'.

=head2 class_from_type()

  $class = Metabase::Fact->class_from_type( $type );

A utility function to invert the operation of the type() method.

=head1 ABSTRACT METHODS

Methods marked as 'required' must be implemented by a Fact subclass.  (The
version in Metabase::Fact will die with an error if called.)

In the documentation below, the terms 'must, 'must not', 'should', etc. have
their usual RFC meanings.

These methods MUST throw an exception if an error occurs.

=head2 content_as_bytes() (required)

  $string = $fact->content_as_bytes;

This method MUST serialize a Fact's content as bytes in a scalar and return it.
The method for serialization is up to the individual fact class to determine.
Some common subclasses are available to handle serialization for common data types.
See L<Metabase::Fact::Hash> and L<Metabase::Fact::String>.

=head2 content_from_bytes() (required)

  $content = $fact->content_from_bytes( $string );
  $content = $fact->content_from_bytes( \$string );

Given a scalar, this method MUST regenerate and return the original content
data structure.  It MUST accept either a string or string reference as an
argument.  It MUST NOT overwrite the Fact's content attribute directly.

=head2 content_metadata() (optional)

  $content_meta = $fact->content_metadata;

If defined in a subclass, this method MUST return a hash reference with
content-specific indexing metadata for the Fact.  The key MUST be the name of
the field for indexing.  ( XXX rjbs -- what format? )

Hash values MUST be an array_ref containing a type and the value for the either be
simple scalars (strings or numbers) or array references.  Type MUST be one of

 Str
 Num

Here is a hypothetical example of content metadata for an image fact:
  
  sub content_metdata {
    my $self = shift;
    return {
      width   => [ Num => _compute_width  ( $self->content ) ],
      height  => [ Num => _compute_height ( $self->content ) ],
      comment => [ Str => _extract_comment( $self->content ) ],
    }
  }

It MUST return C<undef> if no content-specific metadata is available.

=head2 validate_content() (required)

 eval{ $fact->validate_content };

This method SHOULD check for the validity of content within the Fact.  It
MUST throw an exception if the fact content is invalid.  (The return value is
ignored.)

Classes SHOULD call validate_content in their superclass:

  sub validate_content {
    my $self = shift;
    $self->SUPER::validate_content;
    my $error = _check_content( $self );
    die $error if $error;
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

 Portions copyright (c) 2008-2009 by David A. Golden
 Portions copyright (c) 2008-2009 by Ricardo J. B. Signes

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

