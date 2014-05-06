#!/usr/bin/env perl
# Functions for science web tools

# Copyright (c) 2013, 2014 Bryan White, bpcwhite@gmail.com

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
package SWTFunctions;
use strict;
use warnings;
use LWP::Simple;
use utf8;
use Lingua::EN::Ngram;
use HTML::Entities;
use Text::Unidecode qw(unidecode);
use HTML::Scrubber;
use String::Util 'trim';
use Getopt::Long;
use Params::Validate qw(:all);
use HTML::LinkExtractor;
use XML::FeedPP;
use Class::Date qw(:errors date localdate gmdate now -DateParse -EnvC);
use Digest::SHA qw(sha1_hex);
use Data::Dumper;
use XML::Simple;


require Exporter;
my @ISA = qw(Exporter);
my @EXPORT_OK = qw(parse_clean_doc find_tag fetch_sub_docs) ;

sub scrape_rss {
	my %p = validate(
				@_, {
					query	 	=> 1, # optional string of urls; comma separator
					num_results	=> 1, # optional string of target keys
				}
			);
	my $query = $p{'query'};
	my $num_results = $p{'num_results'};
	
	use DateTime;

	my %months = (	'Jan' => 1, 'Feb' => 2, 'Mar' => 3, 'Apr' => 4, 'May' => 5, 'June' => 6, 
					'July' => 7, 'Aug' => 8, 'Sept' => 9, 'Oct' => 10, 'Nov' => 11, 'Dec' => 12);
	my $dt = DateTime->now;
	$dt->set_time_zone('America/Los_Angeles');
	
	my $year = $dt->year;
	my $month = $dt->month;
	my $day = $dt->day;
	
	my $digest = sha1_hex($query);
	my $final_path = $year.'/'.$month.'/'.$day;
	my $final_file = $final_path.'/'.$digest.'.xml';
	my $parsed_file = $final_path.'/'.$digest.'_parsed.csv';

	# Only scrape once a day.
	unless (-d $year) {
		mkdir $year;
	}
	unless (-d $year.'/'.$month) {
		mkdir $year.'/'.$month;
	}
	unless (-d $final_path) {
		mkdir $final_path;
	}
	
	unless (-e $final_file) {
		my $db = 'pubmed';

		#assemble the esearch URL
		my $base = 'http://eutils.ncbi.nlm.nih.gov/entrez/eutils/';
		my $url = $base . "esearch.fcgi?db=$db&term=$query&usehistory=y&retmax=10";
		
		#post the esearch URL
		my $output = get($url);
		print $output."\n";
		
		#parse WebEnv and QueryKey
		my $web = $1 if ($output =~ /<WebEnv>(\S+)<\/WebEnv>/);
		my $key = $1 if ($output =~ /<QueryKey>(\d+)<\/QueryKey>/);
		print $web."\n";
		print $key."\n";
		
		### include this code for ESearch-ESummary
		#assemble the esummary URL
		# $url = $base . "esummary.fcgi?db=$db&query_key=$key&WebEnv=$web";

		#post the esummary URL
		# my $docsums = get($url);
		# print "$docsums";

		### include this code for ESearch-EFetch
		#assemble the efetch URL
		$url = $base . "efetch.fcgi?db=$db&query_key=$key&WebEnv=$web";
		$url .= "&rettype=abstract&retmode=xml&retmax=10";
		print $url."\n";

		#post the efetch URL
		my $data = get($url);
		print "$data";
		$data =~ s/[^[:ascii:]]+//g;
		print "Scraping to: ".$final_file."\n";
		open (SCRAPED, '>'.$final_file);
		print SCRAPED $data;
		close (SCRAPED);
	}

	# Scraping done.
	
	my $source = $final_file;
	my $xml = new XML::Simple;
	my $xml_data = $xml->XMLin($source);
	my $scrubber = HTML::Scrubber->new( allow => [ qw[] ] );
	
	my %parsed = ();
	
	
	foreach my $e (@{$xml_data->{PubmedArticle}}) {
		print Dumper($e);
		# exit;
		# check and process abstract
		my $pubmed_id			= $e->{MedlineCitation}->{PMID}->{content};
		next if !defined($pubmed_id);
		# print Dumper($e->{MedlineCitation}->{Article}->{Abstract}->{AbstractText}->{content})."\n";
		my $abstract = '';
		if(defined($e->{MedlineCitation}->{Article}->{Abstract}->{AbstractText}->{content})) {
			print "A\n";
			$abstract = $e->{MedlineCitation}->{Article}->{Abstract}->{AbstractText}->{content};
		} elsif(defined($e->{MedlineCitation}->{Article}->{Abstract}->{AbstractText})) {
			print "B\n";
			$abstract = $e->{MedlineCitation}->{Article}->{Abstract}->{AbstractText};
		}
		print Dumper($abstract)."|\n";
		next if $abstract eq '';
		$abstract				=~ s/\n//g;
		$parsed{$pubmed_id}->{'abstract'} 		= $abstract;
		$parsed{$pubmed_id}->{'EIdType'}		= $e->{MedlineCitation}->{Article}->{ELocationID}->{EIdType}; # type of electronic archive e.g. doi
		$parsed{$pubmed_id}->{'EIdAccess'}		= $e->{MedlineCitation}->{Article}->{ELocationID}->{content}; # typically doi access point
		$parsed{$pubmed_id}->{'language'}		= $e->{MedlineCitation}->{Article}->{Language}; # article primary language
		$parsed{$pubmed_id}->{'owner'}			= $e->{MedlineCitation}->{Article}->{Owner}; # copyright owner?
		$parsed{$pubmed_id}->{'pubmodel'}		= $e->{MedlineCitation}->{Article}->{PubModel}; # print, electronic, or both?
		$parsed{$pubmed_id}->{'pubtitle'}		= $e->{MedlineCitation}->{Article}->{ArticleTitle};
		$parsed{$pubmed_id}->{'pubtype'}		= $e->{MedlineCitation}->{Article}->{PublicationTypeList}->{PublicationType};
		$parsed{$pubmed_id}->{'journal_abbrv'}	= $e->{MedlineCitation}->{Article}->{Journal}->{ISOAbbreviation};
		$parsed{$pubmed_id}->{'ISSNType'}		= $e->{MedlineCitation}->{Article}->{Journal}->{ISSN}->{content};
		$parsed{$pubmed_id}->{'journal_pub_year'}		= $e->{MedlineCitation}->{Article}->{Journal}->{JournalIssue}->{PubDate}->{Year};
		$parsed{$pubmed_id}->{'journal_pub_month'}		= $e->{MedlineCitation}->{Article}->{Journal}->{JournalIssue}->{PubDate}->{Month};
		$parsed{$pubmed_id}->{'journal_pub_day'}		= $e->{MedlineCitation}->{Article}->{Journal}->{JournalIssue}->{PubDate}->{Day};
		$parsed{$pubmed_id}->{'journal_title'}			= $e->{MedlineCitation}->{Article}->{Journal}->{Title};
		my $author_list_array							= $e->{MedlineCitation}->{Article}->{AuthorList}->{Author};
		my $author_list_full = '';
		my $author_list_abbrv = '';
		foreach my $author (@$author_list_array) {
			if(defined($author->{'Affiliation'})) {
				$author_list_full .= $author->{'LastName'}.";".$author->{'ForeName'}.";".$author->{'Initials'}.";".$author->{'Affiliation'}."|";
				$author_list_abbrv .= $author->{'LastName'}.", ".$author->{'Initials'}.". ";
			}
		}
		$parsed{$pubmed_id}->{'author_list_full'}			= $author_list_full;
		$parsed{$pubmed_id}->{'author_list_abbrv'}			= $author_list_abbrv;

		$parsed{$pubmed_id}->{'pub_status_access'}		= $e->{PubmedData}->{PublicationStatus};
		my $pub_date									= $e->{PubmedData}->{History}->{PubMedPubDate};
		$parsed{$pubmed_id}->{'pub_year'}				= @$pub_date[-1]->{Year};
		$parsed{$pubmed_id}->{'pub_month'}				= @$pub_date[-1]->{Month};
		$parsed{$pubmed_id}->{'pub_day'}				= @$pub_date[-1]->{Day};
		$parsed{$pubmed_id}->{'pub_status'}				= @$pub_date[-1]->{PubStatus};
		$parsed{$pubmed_id}->{'pub_hour'}				= @$pub_date[-1]->{Hour};
		$parsed{$pubmed_id}->{'pub_minute'}				= @$pub_date[-1]->{Minute};
	}
	
	open (PARSED, '>'.$parsed_file);
	my $line_i = 0;
	foreach my $article_key (keys %parsed) {
		print "Parsing... ".$article_key."\n";
		if ($line_i == 0) {
			foreach my $key2 (keys $parsed{$article_key}) {
				print PARSED $key2.",";
			}
		}
		if ($line_i > 0) {
			foreach my $key2 (keys $parsed{$article_key}) {
				print PARSED $parsed{$article_key}->{$key2}."," if defined($parsed{$article_key}->{$key2});
			}
		}
		$line_i++;
		print PARSED "\n";
	}
	close(PARSED);
}

# my $source = $url;
# my $feed = XML::FeedPP->new( $source );
# print "Title: ", $feed->title(), "\n";
# print "Date: ", $feed->pubDate(), "\n";
# foreach my $item ( $feed->get_item() ) {
	# print "Title: ", $item->title(), "\n";
	# print "URL: ", $item->link(), "\n";
	
	
	# print $doc."\n";
	# exit;
	# print "Description: ", $item->description(), "\n";
# }

sub find_tag {
	my $tag 	= shift;
	my $doc_ref = shift;
	
	my $line_num = 0;
	foreach my $line (@$doc_ref) {
	
		if ($line =~ m/$tag/) {
			return $line_num;
		}
		$line_num++;
	}
	
	if ($line_num == 0) {
		return undef;
	}
}

sub find_all_tags {
	my $tag 	= shift;
	my $doc_ref = shift;
	
	my @line_nums = ();
	
	my $line_num = 0;
	foreach my $line (@$doc_ref) {
	
		if ($line =~ m/$tag/) {
			push(@line_nums,$line_num);
		}
		$line_num++;
	}
	
	if ($line_num == 0) {
		return undef;
	}
	return \@line_nums;
}

sub fetch_sub_docs {
	my %p = validate(
				@_, {
					sub_docs 		=> 1, # optional string of urls; comma separator
					target_keys 	=> 1, # optional string of target keys
					num_keys		=> 1, # number of target keys
					num_cur_key		=> 1, # current key to search for
				}
			);

	my $sub_docs 		= $p{'sub_docs'};
	my $target_keys 	= $p{'target_keys'};
	my $num_keys		= $p{'num_keys'};
	my $num_cur_key 	= $p{'num_cur_key'};
	
	# split url and key strings on comma
	my @split_target_keys = split(/,/,$target_keys);
	my @split_sub_docs =  split(/,/,$sub_docs);
	
	my $cur_key = $split_target_keys[$num_cur_key];
	my $cur_doc = $split_sub_docs[$num_cur_key];
	
	print $cur_key."\n";
	print $cur_doc."\n";
	
	# num keys must match url search depth
	# if (scalar(@split_target_keys) != scalar(@split_sub_docs)) {
		# return 0;
	# }
	# print "A";
	# search doc for keyword and extract target url
	my $doc = get $cur_doc;
	my @split_doc = split(/\n/,$doc);
	
	# find key line
	my $keyword_LNS = find_all_tags($cur_key, \@split_doc);

	foreach my $keyword_LN (@$keyword_LNS) {
		my $line_text =  get_line($keyword_LN, \@split_doc);
		get_url_loc($line_text);
	}
	exit;
	# print 
	
	# parse url from line
	# go to next url
	# foreach my $line (@split_doc) {
		# print $line."\n";
	# }
	
}

sub count_keys {
	my $target_keys = shift;
	
	my @split_target_keys = split(/,/,$target_keys);
	
	return scalar(@split_target_keys);
}

sub get_line {
	my $line 	= shift;
	my $doc_ref = shift;
	
	return $doc_ref->[$line];
	
}

sub get_url_loc {
	my $line = shift;
	# print $line."\n";
	my $url_start_key = '"http';
	my $url_end_key = '"/>';
	my $url_end_key2 = '">';
	my $arr_ref = convert_string_array($line);
	my $num_chars = length($line);

	my $url_start = 0;
	my $url_end = 0;
	
	
	for (my $i = 1; $i <= $num_chars; $i++) {
		my $ngram_start = substr($line, $i, 5);
		my $ngram_end = substr($line, $i, 2);
		print $ngram_end."\n";
		
		$url_start = $i if $ngram_start eq $url_start_key;
		$url_end = $i-3 if $ngram_end eq $url_end_key;
		
		# last if $url_end != 0;
	}
	
	print $url_start." => ".$url_end."\n";
	exit;
	for (my $i = $url_start; $i <= $url_end; $i++) {
		print $arr_ref->[$i];
	}
	print "\n";
}

sub get_end_url {

}


sub convert_string_array {
	my $string = shift;
	my @split_string = split(//,$string);
	return \@split_string;
}
