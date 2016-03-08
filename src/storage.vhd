-------------------------------------------------------------------------------
-- Title      : Logic Analyzer Storage Entity
-- Project    : fpga_logic_analyzer
-------------------------------------------------------------------------------
-- File       : storage.vhd
-- Created    : 2016-02-29
-- Last update: 2016-02-29
-- Standard   : VHDL'08
-------------------------------------------------------------------------------
-- Description: This is a RAM storage for recorded data and the input and 
-- output interface
-------------------------------------------------------------------------------
-- Copyright (c) 2016 Ashton Johnson, Paul Henny, Ian Swepston, David Hurt
-------------------------------------------------------------------------------
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 2 of the License, or
-- (at your option) any later version.

-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the
-- GNU General Public License for more details.

-- You should have received a copy of the GNU General Public License along
-- with this program; if not, write to the Free Software Foundation, Inc.,
-- 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version      Author      Description
-- 2016-02-29      0.1      Henny	    Created Entity
-- 2016-03-06      0.2        Henny       Wrote initial architecture
-------------------------------------------------------------------------------
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

entity storage is
    generic ( FIFO_SIZE : integer := 1024
    );
    port(
    clk   --! global clock, ?? MHz
            : in std_logic;
    reset --! Global reset
            : in std_logic;

    -- If we are not always 32 channels of storage, need an input telling me how many channels
            
    --Input FIFO interface from capture
    in_fifo_tdata --! Captured Data
            : in std_logic_vector(31 downto 0);
    in_fifo_tvalid --! indicating tdata has valid data
            : in std_logic;
    in_fifo_tlast  -- no planned usage
            : in std_logic;
    in_fifo_tready  --! outputted by FIFO saying it is ready for more data
            : out  std_logic;
    in_fifo_tfull --! tell capture to stop capturing data
            : out  std_logic;
    in_fifo_tempty --! indicating all data has been transmitted to GUI, can do another capture
            : out  std_logic;
    in_fifo_tflush --! clear all stored data in the FIFO
            : in std_logic;
            
            
    --Output FIFO interface to UART
    out_fifo_tdata --! Captured Data, fed LSByte to UART
            : out std_logic_vector(7 downto 0);
    out_fifo_tvalid --! indicating data has valid data to transmit out
            : out std_logic;
    out_fifo_tlast  --! indicating that the end of this capture data
            : out std_logic;
    out_fifo_tready  --! received from UART, indicating to feed next byte out
            : in  std_logic

    );

end storage;

architecture behave of storage is
    
    -- FIFO storage
    type fifo_bank is array (0 to FIFO_SIZE-1) of std_logic_vector(31 downto 0);
    signal fifo_data : fifo_bank;
    signal in_point : natural range 0 to FIFO_SIZE-1;
    signal out_point : natural range 0 to FIFO_SIZE-1;
    signal last_point : natural range 0 to FIFO_SIZE-1; -- assuming there will only be one last in the fifo at a time
    signal fifo_empty : std_logic;
    
    -- Control signal to re-initialize all the pointers
    signal reset_points : std_logic;

begin

    in_store_blk : block
        type state_in is (INIT, STORE, WAIT_FOR_EMPTY, FLUSH);
        signal in_state : state_in;
    begin
        in_store_pr : process(clk)
        begin
            if rising_edge(clk) then
                if reset='1' then
                    in_point <= 0;
                    in_state <= INIT;
                    last_point <= 0;
                else 
                    -----------------------------
                    -- TLast Control
                    if reset_points='1' then
                        last_point <= 0;
                    elsif in_fifo_tlast='1' and in_state=STORE then
                        last_point <= in_point;
                    end if;
                    -----------------------------
                    -- TFull Control
                    if in_point=FIFO_SIZE then
                        in_fifo_tfull <= '1';
                    else
                        in_fifo_tfull <= '0';
                    end if;
                    -----------------------------
                    -- Input Storage Control
                    case in_state is
                        when INIT =>
                            in_fifo_tready <= '0';
                            if in_fifo_tvalid='1' and last_point=0 and in_point<FIFO_SIZE then
                                in_state <= STORE;
                                -- Say we are ready for next word, for one clock cycle
                                in_fifo_tready <= '1';
                            elsif in_fifo_tflush='1' then
                                in_state <= FLUSH;
                            end if;
                        when STORE =>
                            if in_fifo_tlast='1' then -- last word
                                in_state <= WAIT_FOR_EMPTY;
                                in_fifo_tready <= '0';
                                fifo_data(in_point) <= in_fifo_tdata;
                                in_point <= in_point + 1;
                            elsif in_fifo_tvalid='0' then -- currently no data
                                in_state <= INIT;
                                in_fifo_tready <= '0';
                            else -- every word
                                fifo_data(in_point) <= in_fifo_tdata;
                                in_point <= in_point + 1;
                            end if; -- else stay here and keep storing data
                        when WAIT_FOR_EMPTY =>
                            if reset_points='1' then
                                in_state <= INIT;
                                in_point <= 0;
                            end if;
                        when FLUSH =>
                            in_point <= 0;
                            -- wait until flush is de-asserted before going back to INIT
                            if in_fifo_tflush='0' then
                                in_state <= INIT;
                            end if;
                    end case;
                end if;
            end if;
        end process in_store_pr;
    end block in_store_blk;
        
    output_blk : block
        type state_out is (INIT, GRAB_WORD, OUT_BYTE, NEXT_BYTE,  UPDATE_POINT, WAIT_UPDATE, FLUSH);
        signal out_state : state_out;
        signal data_to_out : std_logic_vector(31 downto 0);
        signal idx : natural range 0 to 3;
    begin
        output_pr : process(clk)
        begin
            if rising_edge(clk) then
                if reset='1' then
                    out_point <= 0;
                    out_state <= INIT;
                    out_fifo_tvalid <= '0';
                    out_fifo_tlast <= '0';
                    out_fifo_tdata <= x"00";
                    idx <= 0;
                    fifo_empty <= '1';
                    reset_points <= '0';
                else
                    case out_state is 
                        when INIT =>
                            idx <= 0;
                            if out_fifo_tready='1' and fifo_empty='0' then
                                out_state <= GRAB_WORD;
                            elsif in_fifo_tflush='1' then
                                out_state <= FLUSH;
                            end if;
                            -- De-asserts FIFO empty if input starts increasing again.
                            if in_point > out_point then
                                fifo_empty <= '0';
                            else
                                fifo_empty <= '1';
                            end if;                            
                        when GRAB_WORD =>
                            if out_point <= in_point then
                                data_to_out <= fifo_data(out_point);
                                out_state <= NEXT_BYTE;
                            end if;
                        when NEXT_BYTE =>
                            out_fifo_tdata <= data_to_out(idx*8 + 7 downto idx*8);
                            if out_fifo_tready='1' then
                                out_fifo_tvalid <= '1';
                                out_state <= OUT_BYTE;
                                -- Signal end of data on last byte, it is 2 instead of 3 since idx has not been updated yet
                                if idx=2 and last_point=out_point then 
                                    out_fifo_tlast <= '1';
                                else
                                    out_fifo_tlast <= '0';
                                end if;
                            end if;
                        when OUT_BYTE =>
                            idx <= idx + 1;
                            -- valid is only high one clock cycle
                            out_fifo_tvalid <= '0';
                            if idx=3 then -- get next word
                                out_state <= UPDATE_POINT;
                            else
                                out_state <= NEXT_BYTE;
                            end if;
                        when UPDATE_POINT =>
                            if out_point = last_point and last_point/=0 then
                                reset_points <= '1';
                                out_state <= WAIT_UPDATE;
                            else
                                out_point <= out_point + 1;
                                out_state <= INIT;
                            end if;
                        when WAIT_UPDATE =>
                            out_point <= 0;
                            -- waiting until the input stream is pointing at the beginning again
                            if in_point=0 then
                                reset_points <= '0';
                                out_state <= INIT;
                            end if;
                        when FLUSH =>
                            out_point <= 0;
                            -- wait until flush is deasserted before going back to init
                            if in_fifo_tflush='0' then
                                out_state <= INIT;
                            end if;
                    end case;
                end if;
            end if;
        end process output_pr;
    end block output_blk;
    
    in_fifo_tempty <= fifo_empty;
    
-- Process to take Deep FIFO output, break it down to 8-bit stream to UART


end architecture behave;

