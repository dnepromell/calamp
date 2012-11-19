# == Schema Information
#
# Table name: messages
#
#  id            :integer          not null, primary key
#  received_data :text             not null
#  hex_data      :text
#  client_addr   :string(255)
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  device_id     :integer
#
require 'base64'
require 'message_parser'

class Message < ActiveRecord::Base

  MOBILE_ID_TYPES = ['OFF', 'ESN', 'IMEI or EID', 'IMSI', 'User Defined Mobile ID',
                     'Phone Number', 'Current IP Address']

  include MessageParser

  attr_accessible :client_addr, :hex_data, :received_data, :device_id

  has_one :options_header
  belongs_to :device, :conditions => "device_id > 0"


  def received_data
    Base64::decode64(self[:received_data])
  end

  def received_data=(value)
    self[:received_data] = Base64::encode64(value)
  end

  def decoded_message
    decoded_msg  = {}
    #options byte => index = 0
    msg          = self.received_data.to_hex_string
    msg          = msg.split(" ")
    options_byte = msg.shift.hex.to_s(2)
    decoded_msg[:options_byte] = options_byte
    # IF bit 0 (LSB) is set it means Mobile Id length is set
    if options_byte[-1] == '1'
      mobile_id_length = msg.shift.hex
      decoded_msg[:mobile_id_length] = mobile_id_length
      decoded_msg[:mobile_id]        = msg.shift(mobile_id_length).join("").to_s.downcase.gsub("f","")
    end
     # IF bit 1 is 1 it means Mobile Id Type length is set
    if options_byte[-2] == '1'
      mobile_id_type_length = msg.shift.hex
      decoded_msg[:mobile_id_type_length]    = mobile_id_type_length
      decoded_msg[:mobile_id_type]           = msg.shift(mobile_id_type_length).join("").hex
    end
    # IF bit 2 is 1 it means Authentication Word length is set. It default value is 4
    if options_byte[-3] == '1'
      auth_word_length = msg.shift.hex
      decoded_msg[:authentication_word_length] = auth_word_length
      decoded_msg[:authentication]             = msg.shift(auth_word_length).join("").hex
    end
    # IF bit 3 is 1 it means Routing length is set. It can be upto 8 bytes
    if options_byte[-4] == '1'
      routing_length = msg.shift.hex
      decoded_msg[:routing_length] = routing_length
      decoded_msg[:routing]        = msg.shift(routing_length).join("").hex
    end
    # IF bit 4 is 1 it means Forwarding length is set. Value normally is 8 if present
    if options_byte[-5] == '1'
      decoded_msg[:forwarding_length]    = msg.shift.hex
      #First 4 bytes denotes forwarding address
      decoded_msg[:forwarding_address]   = msg.shift(4).join("").hex
      #Next 2 bytes denotes forwarding port
      decoded_msg[:forwarding_port]      = msg.shift(2).join("").hex
      #Next 1 byte denotes forwarding protocol
      decoded_msg[:forwarding_protocol]  = msg.shift(1).join("").hex
      #Last 1 byte denotes forwarding operation
      decoded_msg[:forwarding_operation] = msg.shift(1).join("").hex
    end
    # IF bit 5 is 1 it means Response Redirection is set. Usually the value is 6
    if options_byte[-6] == '1'
      decoded_msg[:response_redirection_length]  = msg.shift.hex
      decoded_msg[:response_redirection_address] = msg.shift(4).join("").hex
      decoded_msg[:response_redirection_port]    = msg.shift(2).join("").hex
    end
    message_header = {}
    message_header[:service_type]    = msg.shift.hex
    message_header[:message_type]    = msg.shift.hex
    message_header[:sequence_number] = msg.shift(2).join("").hex

    message_content = {}

    case message_header[:message_type]
      # Event Report Message
      when 2
        message_content = event_report_message(msg)
      when 5
        message_content = application_message(msg)
    end

    {:options_header => decoded_msg,
     :message_header => message_header,
     :message_content => message_content
    }
  end


  def event_report_message(msg)
    message_content = {}
    update_time  = msg.shift(4).join("").hex
    update_time  = Time.at(update_time).utc #in_time_zone('Pacific Time (US & Canada)')
    message_content[:update_time] = update_time.to_s

    time_of_fix  = msg.shift(4).join("").hex
    time_of_fix  = Time.at(time_of_fix).utc #in_time_zone('Pacific Time (US & Canada)')
    message_content[:time_of_fix] = time_of_fix.to_s

    latitude  = msg.shift(4).join("")
    message_content[:latitude] = get_coordinate_from_hex(latitude)

    longitude = msg.shift(4).join("")
    message_content[:longitude] = get_coordinate_from_hex(longitude)

    altitude  = msg.shift(4).join("")
    message_content[:altitude]    = signed_twos_complement_of_hex(altitude) #cm

    message_content[:speed]       = msg.shift(4).join("").hex  #cm / sec
    message_content[:heading]     = msg.shift(2).join("").hex  #cm / sec
    message_content[:satellites]  = msg.shift(1).join("").hex
    message_content[:fix_status]  = msg.shift(1).join("").hex.to_s(2).rjust(8,'0')
    message_content[:carrier]     = msg.shift(2).join("").hex

    #received signal strength
    rssi  = msg.shift(2).join("").hex
    message_content[:rssi]        = convert_to_signed_twos_complement(rssi, 16)

    message_content[:comm_state]  = msg.shift(1).join("").hex.to_s(2).rjust(8,'0')
    message_content[:hdop]        = msg.shift(1).join("").hex * 0.1
    message_content[:inputs]      = msg.shift(1).join("").hex.to_s(2).rjust(8,'0')
    message_content[:unit_status] = msg.shift(1).join("").hex.to_s(2).rjust(8,'0')

    message_content[:event_index] = msg.shift(1).join("").hex
    message_content[:event_code]  = msg.shift(1).join("").hex
    message_content[:accums]      = msg.shift(1).join("").hex
    message_content[:spare]       = msg.shift(1).join("").hex
    total_accumulators            = message_content[:accums].to_i
    (0...total_accumulators).each do |i|
      message_content["accumulator_#{i}".to_sym] = msg.shift(4).join("")
    end
    message_content
  end

  def application_message(msg)
    message_content = {}
    update_time  = msg.shift(4).join("").hex
    update_time  = Time.at(update_time).utc #in_time_zone('Pacific Time (US & Canada)')
    message_content[:update_time] = update_time.to_s

    time_of_fix  = msg.shift(4).join("").hex
    time_of_fix  = Time.at(time_of_fix).utc #in_time_zone('Pacific Time (US & Canada)')
    message_content[:time_of_fix] = time_of_fix.to_s

    latitude  = msg.shift(4).join("")
    message_content[:latitude] = get_coordinate_from_hex(latitude)

    longitude = msg.shift(4).join("")
    message_content[:longitude] = get_coordinate_from_hex(longitude)

    altitude  = msg.shift(4).join("")
    message_content[:altitude]    = signed_twos_complement_of_hex(altitude) #cm

    message_content[:speed]       = msg.shift(4).join("").hex  #cm / sec
    message_content[:heading]     = msg.shift(2).join("").hex  #cm / sec
    message_content[:satellites]  = msg.shift(1).join("").hex
    message_content[:fix_status]  = msg.shift(1).join("").hex.to_s(2).rjust(8,'0')
    message_content[:carrier]     = msg.shift(2).join("").hex

    #received signal strength
    rssi  = msg.shift(2).join("").hex
    message_content[:rssi]        = convert_to_signed_twos_complement(rssi, 16)

    message_content[:comm_state]  = msg.shift(1).join("").hex.to_s(2).rjust(8,'0')
    message_content[:hdop]        = msg.shift(1).join("").hex * 0.1
    message_content[:inputs]      = msg.shift(1).join("").hex.to_s(2).rjust(8,'0')
    message_content[:unit_status] = msg.shift(1).join("").hex.to_s(2).rjust(8,'0')

    message_content[:application_message_type]   = msg.shift(2).join("").hex
    message_content[:application_message_length] = msg.shift(2).join("").hex
    message_content
  end

  #latitude or longitude from Hex
  def get_coordinate_from_hex(hex_value)
    d = signed_twos_complement_of_hex(hex_value)
    d * ( 10 ** -7 ).to_f
  end

  def signed_twos_complement_of_hex(hex_value)
    [hex_value.to_s.scan(/[0-9a-f]{2}/i).reverse.join].pack('H*').unpack('l').first
  end

  def convert_to_signed_twos_complement(integer_value, num_of_bits)
    length       = num_of_bits
    mid          = 2**(length-1)
    max_unsigned = 2**length
    (integer_value >= mid) ? integer_value - max_unsigned : integer_value
  end

  def decode_and_save
    return false if self.id < 1
    hash   = options_header_for_message(self.received_data)
    device = Device.find_by_imei(hash[:mobile_id]) rescue nil
    if device.present?
      self.update_attributes({:device_id => device.id,
                              :hex_data => convert_to_hexa(self.received_data) })
    end
    hash[:message_id] = self.id
    hash[:device_id]  = self.device_id
    record = OptionsHeader.new(hash)
    record.save
  end
end
