use strict;
use warnings;
use ExtUtils::MakeMaker 6.64;
use Module::CPANfile 1.1004;

my $cpanfile = Module::CPANfile->load('cpanfile');
my $prereqs = $cpanfile->prereq_specs;
my %runtime = %{ $prereqs->{runtime}{requires} };
my $perl_version = delete $runtime{perl};

WriteMakefile(
    NAME                => 'APIProxy',
    AUTHOR              => q{YOUR NAME <youremail@example.com>},
    VERSION_FROM        => 'lib/APIProxy.pm',
    ABSTRACT            => 'YOUR APPLICATION ABSTRACT',
    LICENSE             => 'perl',
    PL_FILES            => {},
    MIN_PERL_VERSION    => $perl_version,
    PREREQ_PM           => \%runtime,
    CONFIGURE_REQUIRES  => $prereqs->{configure}{requires},
    BUILD_REQUIRES      => $prereqs->{build}{requires},
    TEST_REQUIRES       => $prereqs->{test}{requires},
    META_MERGE          => {
        'meta-spec' => { version => 2 },
        prereqs => $prereqs,
        optional_features => {
            map {
                $_->identifier => {
                    description => $_->description,
                    prereqs => $_->prereqs->as_string_hash,
                }
            } $cpanfile->features
        },
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'APIProxy-*' },
);
