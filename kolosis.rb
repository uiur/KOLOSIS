# encoding: UTF-8

require 'mechanize'
require 'nokogiri'
require 'pp'
require 'tapp'
require 'ya2yaml'

class String
  def to_hankaku
    self.tr('ａ-ｚＡ-Ｚ０-９', 'a-zA-Z0-9') 
  end
end

module Kolosis
  class Client
    Types = {g: 
              {let: '文学研究科', 
               ed: '教育学研究科', 
               ec: '経済学研究科', 
               p: '薬学研究科', 
               t: '工学研究科', 
               ene: 'エネルギー科学研究科', 
               aa: 'アジア・アフリカ地域研究研究科', 
               i: '情報学研究科', 
               ert: '地球環境学舎', 
               man: '経営管理大学院'}, 
             u: 
              {let: '文学部',
               ed: '教育学部',
               ec: '経済学部', 
               l: '法学部', 
               s: '理学部', 
               med: '医学部医学科', 
               medh: '医学部人間健康科学科', 
               p: '薬学部', 
               t: '工学部', 
               a: '農学部', 
               h: '総合人間学部' }}

    def initialize(args={})
      @args = args
    end
    
    def fetch_and_save(params={type: :common})
      subjects = self.fetch(params)
      save(subjects, 'kulasis_' + params[:type].to_s + '_' + params[:type2].to_s + '.yml')
    end

    def fetch(params={type: :common})
      args = params.merge(@args)
      case params[:type]
      when :common
        CommonScraper.fetch(args)
      when :t
        TechScraper.fetch(args)
      else
        LetScraper.fetch(args)
      end
    end

    private
    def save(subjects, name)
      text = subjects.ya2yaml
      file = File.open(name, 'w')
      file.print text
      file.close
    end
  end

  class Scraper
    module Default
      BASE_URL = "https://student.iimc.kyoto-u.ac.jp/iwproxy/KULASIS/student/"
      URL = 'https://student.iimc.kyoto-u.ac.jp/iwproxy/KULASIS/student/la/syllabus/search'
      Type = :common
      Type2 = :u
      INIT_URL = 'https://cert.iimc.kyoto-u.ac.jp/fw/dfw?AGENT_DFW=http%3a%2f%2fstudent.iimc.kyoto-u.ac.jp%2f&path=%2fiwproxy%2fDMP%2fdp%2fdmp&query='
    end

    def initialize(params={})
      @url = Default::URL
      @init_url = Default::INIT_URL
      @type = params[:type] || Default::Type
      @type2 = params[:type2] || Default::Type2
      @id = params[:id]
      @password = params[:password]
      @client = Mechanize.new
      @result = []
    end

    def self.fetch(params={})
      self.new(params).fetch
    end

    def fetch
      init_client
      until finish?
        connect
        @result += scrape
      end
      @result
    end
    
    def init_client
      raise 'Abstract method called'
    end

    def connect
      raise 'Abstract method called'
    end

    def scrape
      raise 'Abstract method called'
    end

    def finish?
      raise 'Abstract method called'
    end
  end

  class BaseScraper < Scraper
    def initialize(params={})
      super(params)

      @page = 0             # スクレイピングしたページ数
      @per_page = 10        # 1ページに何アイテムあるか
    end

    def init_client
      login

      @size = get_size      # アイテムの全件数
    end

    def finish?
      @size <= @page * @per_page
    end

    def connect
      @page += 1
      @client.get(@url + "?page=#{@page}")
    end

    def get_size
      raise 'Not Implemented'
    end

    def login
      @client.get(@init_url) do |page|
        page.form_with(:action => "/fw/dfw") do |f|
          f.ACCOUNTUID = @id
          f.PASSWORD = @password
        end.click_button
        @client.click(@client.page.link_with(:text => /KULASIS/))
        pp page.title
      end

    end
 
    def sjis_to_nokogiri
      Nokogiri::HTML(@client.page.body, nil, 'sjis')
    end

    def url_to(path)
      Default::BASE_URL + path
    end
 end

  class CommonScraper < BaseScraper
    def scrape
      doc = sjis_to_nokogiri
      trs = doc.css('table.standard_list > tr').to_a
      trs.shift(3)
      trs.pop

      trs.map do |tr|
        tr.css('br').each{|b| b.replace("\n") }
        tds = tr.css('td').map{ |td| td.inner_text.strip }
        
        # 詳細ページからスクレイピング
        detail = scrape_detail(tr: tr, tds: tds) rescue {}

        pp item = {:code => tds[0].strip.to_i,
                   :name => tds[1].to_hankaku,
                   :teachers => tds[2].split("\n").map{|t| t.gsub(/　/, '').to_hankaku},
                   :periods => tds[3].split("\n"),
                   :term => tds[4],
                   :category => tds[5].to_hankaku.gsub(/\s/, ''),
                   :faculty => @type}.merge(detail)
      end
    end

    def scrape_detail(option={})
      number = option[:tr].css('td a').last["href"].gsub(/print\?no=(.*)/){$1}
      @client.get(url_to("la/support/lecture_detail?no=#{number}"))
      detail = sjis_to_nokogiri

      name = detail.css('span.x100 b')[0].inner_text.strip
      room = detail.css('table[border="0"][cellspacing="0"][cellpadding="2"] tr[valign="top"]').last.children[2].inner_text.strip
      
      {name: name, room: room}
    end

    def get_size
      @client.get(@url).search('//div[@class="content"]/div[@class="explanation"]/b').inner_text.to_i
    end
  end

  # 工学部以外の学部専門科目
  class LetScraper < CommonScraper
    def initialize(params={})
      super(params)

      @url = url_to "#{@type2}/#{@type}/syllabus/search"
    end

    def scrape_detail(option={})
      path = option[:tr].css('td a').first["href"]
      @client.get(url_to("#{@type2}/#{@type}/syllabus/#{path}"))
      detail = sjis_to_nokogiri

      name = detail.css('span.x100 b')[0].inner_text.strip
      room = nil
      detail.css('tr[valign="top"]').each do |tr|
        if tr.inner_text.gsub(/\s/,'').strip =~ /\(教室\)/
          room = tr.inner_text.gsub(/\s/,'').strip.scan(/\(教室\)(.*)\(/).flatten[0]

          break
        end
      end

      {name: name, room: room}
    end

    def get_size
      @client.get(@url).search('//div[@class="content"]/div/b').inner_text.to_i
    end
  end

  # 工学部の専門科目
  class TechScraper < LetScraper
    def scrape_detail(option={})
      course = option[:tds][6]
      url = option[:tr].css('td a').first["href"]
      @client.get(url)
      detail = Nokogiri::HTML(@client.page.body)

      room = nil
      detail.css('table.basic tr').each do |tr|
        if tr.css('th').inner_text =~ /講義室/
          room = tr.css('td').inner_text.gsub(/\s/, '').strip 
          break
        end
      end

      {room: room, course: course}
    end
  end
end
