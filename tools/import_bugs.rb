#!/usr/bin/env ruby

unless `ps aux | grep '#{File.basename(__FILE__)}' | grep -v grep | grep -v #{Process.pid} | grep -v '.bash_profile'`.empty?
  puts 'already anothor running, now exit...'
  exit(-1)
end

require 'yaml'
@root_path = File.expand_path(File.dirname(__FILE__))
require 'active_record'
rails_env = ENV['RAILS_ENV'] || 'development'
config = YAML::load(File.open(@root_path+"/../config/database.yml"))[rails_env]
config['database'] = File.expand_path(File.join(@root_path, '..', config['database'])) if config['database'].include? 'sqlite'
ActiveRecord::Base.establish_connection (config)

class Bug < ActiveRecord::Base

end

require 'open-uri'
require 'nokogiri'
require 'rubygems'
require 'colorize'

class String
  def string_between_markers marker1, marker2
    self[/#{Regexp.escape(marker1)}(.*?)#{Regexp.escape(marker2)}/m, 1]
  end

  def string_between_markers_full marker1, marker2
    self[/#{Regexp.escape(marker1)}(.*?)#{Regexp.escape(marker2)}/m]
  end

  def to_wmid
    self.split('-')[2].to_i
  end

  def to_email
    a=self
    e=""
    r=a[0,2].to_i(16)
    n=2

    while a.length-n>0
      i=a[n,2].to_i(16)^r
      e+=i.chr
      n+=2
    end
    e
  end
end


class WooyunDumper

  #完整同步
  def self.full_sync
    page=1
    while process_page(page) >= 0
      page = page+1
      sleep 0.2
    end

    content_sync

    puts "----> Finished!".green
  end

  #差异同步
  def self.sync
    page=1
    while process_page(page) == 1
      page = page+1
      sleep 0.2
    end

    content_sync

    puts "----> Finished!".green
  end

  #差异同步，如果count不为0，那么到找到的id位置就结束，否则一直找
  def self.bruteforce_sync(startid=0, count=0)
    startid = get_max_wmid() if startid==0
    endid = 0
    endid = get_max_wmid()-count if count>0
    if startid == 0
      put "startid is 0, you should set the value !".red
    end

    while startid>endid
      wid = 'wooyun-2015-0'+startid.to_s
      if Bug.find_by_wmid(startid)
        break if count>0 #找到数据库有的数据为止
      else
        #puts "checking #{wid}"
        if process_bug(wid, true) {|data| data[:ishide] = true; data}
          last_error_time = 0
          puts "-------> found hidden bug of #{wid}...      ".yellow
        end
        #sleep 0.2
      end
      startid = startid - 1
    end

    content_sync

    puts "----> Finished!".green
  end

  #是否不检查数据库是否存在
  def self.process_bug(wid, without_check_db=false)
    print "\r-------> Process bug of #{wid}...      ".blue
    url = "http://www.wooyun.org/bugs/#{wid}"
    c = open(url).read
    c = utf8(c)
    c = replace_cfemail(c)
    doc = Nokogiri::HTML(c)
    content = doc.css('div.content')
    if content
      content = content.inner_html
      if without_check_db
        data = parse_content(content, wid)
        if data
          data = yield(data) if block_given?
          bug = Bug.new(data)
          bug.save
        else
          return false
        end
      else
        bug = Bug.find_by_wmid(wid.to_wmid)
        if bug
          bug.content = content
          bug.save
        else
          puts "----> No record of #{wid} at database!".red
          return false
        end
      end

    else
      puts "----> No content of #{url} ".red
      return false
    end
    true
  end

  private
  # return 0没有新增数据，1获取数据，－1没有获取数据
  def self.process_page(page)
    code = 0
    puts "----> Process page #{page}...".green
    url = "http://www.wooyun.org/bugs/new_public/page/#{page}"
    c = open(url).read
    c = utf8(c)
    c = replace_cfemail(c)
    doc = Nokogiri::HTML(c)
    links = doc.css('table.listTable tbody tr td a')
    if links.size>0
      links.each{|a|
        wid = a['href'].split('/')[2]
        title = a.text
        if Bug.exists?(wmid:wid.to_wmid)
          print "\rExists record of wid #{wid} #{title}...                      "
        else
          bug = Bug.new {|b|
            b.wid = wid
            b.wmid = wid.to_wmid
            b.title = title
          }
          bug.save
          code  = 1
          puts "Found wid #{wid} #{title}...".green
        end
      }
    else
      puts "----> No record of #{url}".red
      code = -1
    end
    code
  end



  def self.content_sync
    Bug.where("content IS NULL").each{|b|
      process_bug(b.wid)
      b = Bug.find_by_wmid(b.wid.to_wmid)
      unless process_content(b)
        puts "process content of #{b.wid} error!".red
        exit
      end
    }

    #提取content内容解析
    Bug.where("created_time IS NULL or published_time IS NULL or iscloud IS NULL or ismoney IS NULL or author IS NULL or corporation IS NULL or rank IS NULL").each{|b|
      unless process_content(b)
        puts "process content of #{b.wid} error!".red
        exit
      end
    }

    Bug.where("wmid IS NULL").each{|b|
      print "process wmid : #{b.wid}\r"
      b.wmid = b.wid.to_wmid
      b.save
    }
  end

  def self.parse_content(c, wid)
    return nil if c.include?('该漏洞不存在或未通过审核') || !c.include?('细节向公众公开')

    c = replace_cfemail(c)
    content = Nokogiri::HTML(c)
    data = {:corporation=>nil, :author=>nil, :iscloud=>false, :ismoney=>false, :wid=>wid, :content=>c, :wmid=>wid.to_wmid, :rank=>0}

    if content.css('h3.wybug_date').size>0 #事件
      data[:created_time] = content.css('h3.wybug_date')[0].text.split('：')[1].strip
      data[:published_time] = content.css('h3.wybug_open_date')[0].text.split('：')[1].strip
      data[:corporation] = content.css('h3.wybug_corp a')[0].text.strip
      data[:author] = content.css('h3.wybug_author a')[0].text.strip
      data[:title] = content.css('h3.wybug_title')[0].text.split('：')[1].strip
    else #通用？
      data[:created_time] = c.string_between_markers("<h3>提交时间：","h3").strip
      data[:published_time] = c.string_between_markers("<h3>公开时间：","h3").strip
      corporation = c.string_between_markers("<h3>相关厂商：","h3").strip
      data[:corporation] = corporation.string_between_markers(">","</a>").strip
      author = c.string_between_markers("<h3>漏洞作者：","h3").strip
      data[:author] = author.string_between_markers(">","</a>").strip
      data[:title] = c.string_between_markers("<h3>漏洞标题：","h3").strip
    end

    #baidu云加速的email保护
    data[:title] = content.css('title')[0].text if data[:title].include?('[email protected]')

    if c.include?("漏洞Rank：")
      rank = c.string_between_markers("漏洞Rank：","</p>").strip
      if !rank.nil? && rank.size>0
        rank = rank.split('(')[0].strip if rank.include?('(')
        rank = rank.to_i
        data[:rank] = rank if rank>0
      end

    end

    if data[:corporation].nil? || data[:author].nil? || data[:created_time].nil? || data[:published_time].nil?
      puts "----> Parse content of #{wid} failed, maybe format has been changed!".red
      return nil
    end

    c.scan(/\<img src="\/images\/(.*?)" alt="" class="credit">/).each{|a|
      data[:iscloud] = true if a[0] === "credit.png"
      data[:ismoney] = true if a[0][0] === "m"
    }
    data
  end

  def self.process_content(b)
    print "\r-------> Process content of #{b.wid}...      ".blue

    #编码错误，需要重新更新
    b.content.force_encoding("UTF-8")
    unless b.content.valid_encoding?
      puts "invalid encoding".yellow
      b.content = b.content.encode('UTF-8', :undef => :replace, :invalid => :replace, :replace => '^')
      b.save
    end

    data = parse_content(b.content, b.wid)
    if data
      b.created_time = data[:created_time]
      b.published_time = data[:published_time]
      b.iscloud = data[:iscloud]
      b.ismoney = data[:ismoney]
      b.corporation = data[:corporation]
      b.author = data[:author]
      b.title = data[:title]
      b.rank = data[:rank]
      b.save
    else
      puts "no data of #{b.wid}".red
    end

    true
  end

  def self.get_max_wmid()
    max_id = Bug.select('wmid').order('length(wmid) desc, wmid desc').limit(1).first
    if max_id
      return max_id['wmid'].to_i
    end
    nil
  end

  def self.utf8(c)
    c.force_encoding("UTF-8")
    unless c.valid_encoding?
      puts "invalid encoding".yellow
      c = c.encode('UTF-8', :undef => :replace, :invalid => :replace, :replace => '^')
    end
    c
  end

  def self.replace_cfemail(content)
    content.scan(/<(a|span)#{Regexp.escape(' class="__cf_email__"')}.*?#{Regexp.escape('</script>')}/im).each{|m|
      m = $& if m.kind_of?(Array)
      cfemail = m.string_between_markers('data-cfemail="', '"')
      if cfemail
        #puts cfemail
        email = cfemail.to_email
        puts "Find email : #{email}   "
        content[m] = email if content.include?(m) #
      end
    }
    content
  end
end

#WooyunDumper.process_page(77)
WooyunDumper.sync
WooyunDumper.bruteforce_sync(WooyunDumper.get_max_wmid, 1000)

