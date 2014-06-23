# -*- encoding: utf-8 -*-
module EnjuNdl
  module NdlSearch
    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods
      def import_jpno(jpno)
        manifestation = Manifestation.import_from_ndl_search(:jpno => jpno)
        manifestation
      end

      def import_isbn(isbn)
        manifestation = Manifestation.import_from_ndl_search(:isbn => isbn)
        manifestation
      end

      def import_from_ndl_search(options)
        manifestation = nil
        lisbn = nil
        doc = nil

        if options[:jpno]
          jpno = options[:jpno].gsub(/^JP/, "")
          nbn = jpno
          nbn = "JP#{jpno}" unless /^JP/ =~ jpno
          manifestation = Manifestation.where(nbn: nbn)

          return manifestation.first if manifestation.present?

          doc = return_xml_from_jpno(jpno)
        else
          lisbn = Lisbn.new(options[:isbn])
          raise EnjuNdl::InvalidIsbn unless lisbn.valid?
          manifestation = Manifestation.find_by_isbn(lisbn.isbn)

          return manifestation if manifestation.present?

          doc = return_xml(lisbn.isbn)
        end

        raise EnjuNdl::RecordNotFound unless doc
        #raise EnjuNdl::RecordNotFound if doc.at('//openSearch:totalResults').content.to_i == 0
        import_record(doc)
      end

      def import_record(doc)
        iss_itemno = URI.parse(doc.at('//dcndl:BibAdminResource[@rdf:about]').values.first).path.split('/').last
        identifier = Identifier.where(:body => iss_itemno, :identifier_type_id => IdentifierType.where(:name => 'iss_itemno').first_or_create.id).first
        return identifier.manifestation if identifier

        jpno = doc.at('//dcterms:identifier[@rdf:datatype="http://ndl.go.jp/dcndl/terms/JPNO"]').try(:content)

        publishers = get_publishers(doc)

        # title
        title = get_title(doc)

        # date of publication
        pub_date = doc.at('//dcterms:date').try(:content).to_s.gsub(/\./, '-')
        unless pub_date =~ /^\d+(-\d{0,2}){0,2}$/
          pub_date = nil
        end
        if pub_date
          date = pub_date.split('-')
          if date[0] and date[1]
            date = sprintf("%04d-%02d", date[0], date[1])
          else
            date = pub_date
          end
        end

        isbn = Lisbn.new(doc.at('//dcterms:identifier[@rdf:datatype="http://ndl.go.jp/dcndl/terms/ISBN"]').try(:content).to_s).try(:isbn)
        issn = StdNum::ISSN.normalize(doc.at('//dcterms:identifier[@rdf:datatype="http://ndl.go.jp/dcndl/terms/ISSN"]').try(:content))
        issn_l = StdNum::ISSN.normalize(doc.at('//dcterms:identifier[@rdf:datatype="http://ndl.go.jp/dcndl/terms/ISSNL"]').try(:content))

        carrier_type = content_type = nil
        doc.xpath('//dcndl:materialType[@rdf:resource]').each do |d|
          case d.attributes['resource'].try(:content)
          when 'http://ndl.go.jp/ndltype/Book'
            carrier_type = CarrierType.where(:name => 'print').first
            content_type = ContentType.where(:name => 'text').first
          when 'http://purl.org/dc/dcmitype/Sound'
            content_type = ContentType.where(:name => 'audio').first
          when 'http://purl.org/dc/dcmitype/MovingImage'
            content_type = ContentType.where(:name => 'video').first
          when 'http://ndl.go.jp/ndltype/ElectronicResource'
            carrier_type = CarrierType.where(:name => 'file').first
          end
        end

        admin_identifier = doc.at('//dcndl:BibAdminResource[@rdf:about]').attributes["about"].value
        description = doc.at('//dcterms:abstract').try(:content)
        price = doc.at('//dcndl:price').try(:content)
        volume_number_string = doc.at('//dcndl:volume/rdf:Description/rdf:value').try(:content)
        extent = get_extent(doc)
        publication_periodicity = doc.at('//dcndl:publicationPeriodicity').try(:content)
        statement_of_responsibility = doc.xpath('//dcndl:BibResource/dc:creator').map{|e| e.content}.join("; ")
        location = doc.at('//dcndl:location').try(:content)

        manifestation = nil
        Agent.transaction do
          publisher_agents = Agent.import_agents(publishers)

          manifestation = Manifestation.new(
            :manifestation_identifier => admin_identifier,
            :original_title => title[:manifestation],
            :title_transcription => title[:transcription],
            :title_alternative => title[:alternative],
            :title_alternative_transcription => title[:alternative_transcription],
            # TODO: NDLサーチに入っている図書以外の資料を調べる
            #:carrier_type_id => CarrierType.where(:name => 'print').first.id,
            :pub_date => date,
            :description => description,
            :volume_number_string => volume_number_string,
            :price => price,
#            :statement_of_responsibility => statement_of_responsibility,
            :start_page => extent[:start_page],
            :end_page => extent[:end_page],
            :height => extent[:height],
            :place_of_publication => location
          )
          identifier = {}
          if isbn
            identifier[:isbn] = Identifier.new(:body => isbn)
            identifier[:isbn].identifier_type = IdentifierType.where(:name => 'isbn').first_or_create
            manifestation.isbn = isbn # for enju_trunk
          end
          if iss_itemno
            identifier[:iss_itemno] = Identifier.new(:body => iss_itemno)
            identifier[:iss_itemno].identifier_type = IdentifierType.where(:name => 'iss_itemno').first_or_create
          end
          if jpno
            identifier[:jpno] = Identifier.new(:body => jpno)
            identifier[:jpno].identifier_type = IdentifierType.where(:name => 'jpno').first_or_create
            manifestation.nbn = "JP#{jpno}" # for enju_turnk
          end
          if issn
            identifier[:issn] = Identifier.new(:body => issn)
            identifier[:issn].identifier_type = IdentifierType.where(:name => 'issn').first_or_create
            manifestation.issn = issn # for enju_turnk
          end
          if issn_l
            identifier[:issn_l] = Identifier.new(:body => issn_l)
            identifier[:issn_l].identifier_type = IdentifierType.where(:name => 'issn_l').first_or_create
          end
          manifestation.carrier_type = carrier_type if carrier_type
          manifestation.manifestation_content_type = content_type if content_type
          manifestation.periodical = true if publication_periodicity
          if manifestation.save
            identifier.each do |k, v|
              manifestation.identifiers << v if v.valid?
            end
            manifestation.publishers << publisher_agents
            create_additional_attributes(doc, manifestation)
            create_series_statement(doc, manifestation)
          end
        end

        #manifestation.send_later(:create_frbr_instance, doc.to_s)
        catalog = Catalog.where(name: 'ndl').first
        manifestation.catalog = catalog if catalog # for enju_trunk
        return manifestation
      end

      def create_additional_attributes(doc, manifestation)
        title = get_title(doc)
        creators = get_creators(doc).uniq
        languages = get_languages(doc).uniq
        subjects = get_subjects(doc).uniq
        classifications = get_classifications(doc).uniq

        Agent.transaction do
          creator_agents = Agent.import_agents(creators)
          content_type_id = ContentType.where(:name => 'text').first.id rescue 1
          manifestation.creators << creator_agents
          if languages.present?
            manifestation.languages << languages
            if languages.collect(&:name).include?('Japanese')
              manifestation.jpn_or_foreign = nil
              manifestation.jpn_or_foreign = 0 if languages.size == 1
            else
              manifestation.jpn_or_foreign = 1
            end
          else
            manifestation.languages << Language.where(:name => 'unknown')
          end
          if defined?(EnjuSubject)
            #TODO ndlsh が大文字で登録されていた場合、バリデーションに引っ掛かりエラーが起きるため大文字でも検索
            subject_heading_type = SubjectHeadingType.where(:name => 'ndlsh').first
            subject_heading_type = SubjectHeadingType.where(:name => 'NDLSH').first if subject_heading_type.nil?
            subject_heading_type = SubjectHeadingType.create(:name => 'ndlsh') if subject_heading_type.nil?
            subjects.each do |term|
              subject = Subject.where(:term => term[:term]).first
              unless subject
                subject = Subject.new(term)
                subject.subject_heading_types << subject_heading_type # for enju_trunk
                subject.subject_type = SubjectType.where(:name => 'Concept').first_or_create
              end
              #if subject.valid?
                manifestation.subjects << subject
              #end
              #subject.save!
            end
            manifestation.classifications = classifications
          end
        end
      end

      def search_ndl(query, options = {})
        options = {:dpid => 'iss-ndl-opac', :item => 'any', :idx => 1, :per_page => 10, :raw => false}.merge(options)
        doc = nil
        results = {}
        startrecord = options[:idx].to_i
        if startrecord == 0
          startrecord = 1
        end
        url = "http://iss.ndl.go.jp/api/opensearch?dpid=#{options[:dpid]}&#{options[:item]}=#{format_query(query)}&cnt=#{options[:per_page]}&idx=#{startrecord}"
        if options[:raw] == true
          open(url).read
        else
          RSS::Rss::Channel.install_text_element("openSearch:totalResults", "http://a9.com/-/spec/opensearchrss/1.0/", "?", "totalResults", :text, "openSearch:totalResults")
          RSS::BaseListener.install_get_text_element "http://a9.com/-/spec/opensearchrss/1.0/", "totalResults", "totalResults="
          feed = RSS::Parser.parse(url, false)
        end
      end

      def search_ndl_sru(query, options = {})
        options = {:operation => 'searchRetrieve', :recordScheme => 'dcndl', :startRecord => 1, :maximumRecords => 10}.merge(options)
        doc = nil
        results = {}
        startrecord = options[:startRecord].to_i
        if startrecord == 0
          startrecord = 1
        end
        url = "http://iss.ndl.go.jp/api/sru?operation=#{options[:operation]}&recordSchema=#{options[:recordScheme]}&query=#{format_query(query)}&startRecord=#{options[:startRecord]}&maximumRecords=#{options[:maximumRecords]}&onlyBib=true"
        if options[:raw] == true
          open(url).read
        else
          xml = open(url).read
          response = Nokogiri::XML(xml).at('//xmlns:recordData')
        end
      end

      def normalize_isbn(isbn)
        if isbn.length == 10
          Lisbn.new(isbn).isbn13
        else
          Lisbn.new(isbn).isbn10
        end
      end

      def return_xml(isbn)
        protocol = Setting.try(:ndl_api_type) rescue nil
        if protocol == 'sru'
          response = self.search_ndl_sru("isbn=#{isbn}")
          doc = Nokogiri::XML(response.content)
        else # protocol == 'opensearch'
          rss = self.search_ndl(isbn, {:dpid => 'iss-ndl-opac', :item => 'isbn'})
          if rss.channel.totalResults.to_i == 0
            isbn = normalize_isbn(isbn)
            rss = self.search_ndl(isbn, {:dpid => 'iss-ndl-opac', :item => 'isbn'})
          end
          if rss.items.first
            doc = Nokogiri::XML(open("#{rss.items.first.link}.rdf").read)
          end
        end
      end

      def return_xml_from_jpno(jpno)
        protocol = Setting.try(:ndl_api_type) rescue nil
        if protocol == 'sru'
          response = self.search_ndl_sru("jpno=#{isbn}")
          doc = Nokogiri::XML(response.content)
        else # protocol == 'opensearch'
          rss = self.search_ndl(jpno, {:dpid => 'iss-ndl-opac', :item => 'jpno'})
          if rss.items.first
            doc = Nokogiri::XML(open("#{rss.items.first.link}.rdf").read)
          end
        end
      end

      private
      def get_title(doc)
        title = {
          :manifestation => doc.xpath('//dc:title/rdf:Description/rdf:value').collect(&:content).join(' '),
          :transcription => doc.xpath('//dc:title/rdf:Description/dcndl:transcription').collect(&:content).join(' '),
          :alternative => doc.at('//dcndl:alternative/rdf:Description/rdf:value').try(:content),
          :alternative_transcription => doc.at('//dcndl:alternative/rdf:Description/dcndl:transcription').try(:content)
        }
      end

      def get_creators(doc)
        creators = []
        doc.xpath('//dcterms:creator/foaf:Agent').each do |creator|
          creators << {
            :full_name => creator.at('./foaf:name').content,
            :full_name_transcription => creator.at('./dcndl:transcription').try(:content),
            :agent_identifier => creator.attributes["about"].try(:content)
          }
        end
        creators
      end

      def get_subjects(doc)
        subjects = []
        doc.xpath('//dcterms:subject/rdf:Description').each do |subject|
          subjects << {
            :term => subject.at('./rdf:value').content
            #:url => subject.attribute('about').try(:content)
          }
        end
        subjects
      end

      def get_classifications(doc)
        classifications = []
        # NDLC, NDC9, DDC
        classification_urls = doc.xpath('//dcterms:subject[@rdf:resource]').map{|subject| subject.attributes['resource'].value}
        classification_urls.each do |url|
          array = url.split('/')
          if array.last == 'about' # DDC
            type = 'dc'
            identifier = array.reverse[1] 
          else # NDLC, NDC9
            type = array.reverse[1]
            identifier = array.last
          end
          classifications << get_or_create_classification(type, identifier)
        end

        # NDC8, NDC, LCC, UDC, GHQ/SCAP, USCAR, MCJ
        classification_urls = doc.xpath('//dc:subject[@rdf:datatype]').map{|subject| subject.attributes['datatype'].value}
        classification_urls.each do |url|
          type = url.split('/').last.downcase
          identifier = doc.xpath("//dc:subject[@rdf:datatype='#{url}']").collect(&:content).join('')
          classifications << get_or_create_classification(type, identifier)
        end
        classifications = classifications.compact
      end

      def get_or_create_classification(type, identifier)
        classification_type = ClassificationType.where(:name => type).first
        if classification_type
          classification = Classification.where(:classification_type_id => classification_type.id, :classification_identifier => identifier).first ||
                           Classification.where(:classification_type_id => classification_type.id, :classification_identifier => identifier, :category => I18n.t('enju_ndl.undefined_classification')).create
        end
        classification
      end

      def get_languages(doc)
        languages = []
        doc.xpath('//dcterms:language[@rdf:datatype="http://purl.org/dc/terms/ISO639-2"]').each do |language|
          search_lang = language.try(:content).try(:downcase)
          languages << Language.where(:iso_639_2 => search_lang).first if search_lang.present?
        end
        languages
      end

      def get_publishers(doc)
        publishers = []
        doc.xpath('//dcterms:publisher/foaf:Agent').each do |publisher|
          publishers << {
            :full_name => publisher.at('./foaf:name').content,
            :full_name_transcription => publisher.at('./dcndl:transcription').try(:content),
            :agent_identifier => publisher.attributes["about"].try(:content)
          }
        end
        return publishers
      end

      def get_extent(doc)
        extent = doc.at('//dcterms:extent').try(:content)
        value = {:start_page => nil, :end_page => nil, :height => nil}
        if extent
          extent = extent.split(';')
          page = extent[0].try(:strip)
          if page =~ /\d+p/
            value[:start_page] = 1
            value[:end_page] = page.to_i
          end
          height = extent[1].try(:strip)
          if height =~ /\d+cm/
            value[:height] = height.to_i
          end
        end
        value
      end

      def create_series_statement(doc, manifestation)
        series = series_title = {}
        series[:title] = doc.at('//dcndl:seriesTitle/rdf:Description/rdf:value').try(:content)
        series[:title_transcription] = doc.at('//dcndl:seriesTitle/rdf:Description/dcndl:seriesTitleTranscription').try(:content)
        if series[:title]
          series_title[:title] = series[:title].split(';')[0].strip
          series_title[:title_transcription] = series[:title_transcription]
        end

        if series_title[:title]
          series_statement = SeriesStatement.where(:original_title => series_title[:title]).first
          unless series_statement
            series_statement = SeriesStatement.new(
              :original_title => series_title[:title],
              :title_transcription => series_title[:title_transcription]
            )
            series_statement.root_manifestation = series_statement.initialize_root_manifestation
          end
        end

        if series_statement.try(:save)
          manifestation.series_statement = series_statement # for enju_trunk
        end
        manifestation
      end

      def format_query(query)
        URI.escape(query.to_s.gsub('　',' '))
      end
    end

    class AlreadyImported < StandardError
    end
  end
end
