-- ===========================================================================
--! @file   evnt_dec_controller.vhd translates the configuration for a particular event into actions
--!
--! @author Felipe Torres González <felipe.torresgonzalez@ess.eu>
--!
--! @date 20210209
--! @version 0.1
--!
--! Company: European Spallation Source ERIC \n
--! Platform: picoZED 7030 \n
--! Carrier board: Tallinn picoZED carrier board (aka FPGA-based IOC) rev. B \n
--!
--! @copyright
--!
--! Copyright (C) 2019- 2020 European Spallation Source ERIC \n
--! This program is free software: you can redistribute it and/or modify
--! it under the terms of the GNU General Public License as published by
--! the Free Software Foundation, either version 3 of the License, or
--! (at your option) any later version. \n
--! This program is distributed in the hope that it will be useful,
--! but WITHOUT ANY WARRANTY; without even the implied warranty of
--! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--! GNU General Public License for more details. \n
--! You should have received a copy of the GNU General Public License
--! along with this program.  If not, see <http://www.gnu.org/licenses/>.
-- ===========================================================================

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library work;
use work.evr_pkg.ALL;

--!@brief evnt_dec_controller translates the configuration for a particular event into actions
--!@details
--! When an event arrives into the picoEVR, the configuration word associated to that event
--! is fetch from the mapping RAM. The configuration word holds 3 main fields:
--! * Internal Function (32 bits): Allows matching event codes to internal functions, 
--!   such as the Heartbeat
--! * Pulse Generator Trigger action (32 bits): Produces a pulse in the trigger input for
--!   a particular Pulse Generator (or many). Up to 32 Pulse Generators are indexable.
--! * Pulse Generator Set action (32 bits): Forces a (or many) Pulse Generator to set HIGH its
--!   output. Up to 32 Pulse Generators are indexable.
--! * Pulse Generator Reset action (32 bits): Clears the set input or resets the counter for
--!   a (or many) Pulse Generator. Up to 32 Pulse Generators are indexable.
--!
--! In order to simplify the controller while allowing consecutive event arrivals,
--! the controller assumes the following:
--!
--! 1. Pulse generators are able to detect a trigger pulse whose width is 1 clock cycle of the
--!    event clock, i.e. the controller shall raise the trigger signal after the event arrival and
--!    may lower it in the next cycle.
--! 2. Pulse generators are able to detect a transition in the set input from HIGH level to LOW
--!    level. That transition will result from the arrival of an event whose reset bit is linked
--!    to a Pulse Generator. This particular Pulse Generator shall reset its status after the
--!    set input changes from HIGH to LOW levels.
--! 3. Modules which implement the internal functions linked to the internal function bits hold
--!    in the first field of the configuration word read from the mapping RAM, shall consider if
--!    they should trigger by edge of by level. An example to understand this sentence:
--!    T1: event A is received. Bit 127 is active (save event to FIFO).
--!        The event_dec_controller will generate a risign edge in the signal which is fed into
--!        the Event FIFO module.
--!    T2: The Event FIFO module detects the rising edge of the flag signal and proceeds storing
--!        the previous event code into the FIFO.
--!        In this cycle, a new event is received (event B) which also has the bit 127 active in
--!        its configuration word fetch from the mapping RAM.
--!        The event_dec_controller has no gap to make a transition H->L->H for the save event
--!        to FIFO flag, so it just keeps the flag in HIGH level.
--!    T3: The Event FIFO module doesn't receive a new edge in the flag signal, so it has to 
--!        consider that on each new cycle, if the flag signal is HIGH, the event code has to
--!        be introduced into the FIFO.
--!    In order to design a simple event decoder controller which can react to new events each
--!    new edge of the event clock, the former behaviour is needed. As explained, there's no 
--!    free cycles between events to produce the transition H->L->H.
--!    This situation could be handled in many ways (FIFO, faster clock, ...), but the simplest
--!    option is to consider (3) and trust the modules which read the function flags will 
--!    implement this signaling behaviour.
entity evnt_dec_controller is
    port (
        --! Rx clock with DC
        i_evnt_clk      : in std_logic;
        --! Rx path reset
        i_reset         : in std_logic;
        --! Flag which indicates when a new valid configuration word is ready 
        --! at i_evnt_cfg
        i_evnt_rdy      : in std_logic;
        --! Raw data word (128 bit) as it is read from the mapping RAM
        i_evnt_cfg      : in std_logic_vector(c_EVNT_MAP_DATA_WIDTH-1 downto 0);
        --! Control flags to trigger, reset or set each one of the Pulse Generators
        o_pgen_map_reg  : out pgen_map_reg;
        --! Control flags to activate internal functions
        --! Each flag will be active for 1 clock period of the event clock, and it
        --! relates to the event code received in the previous 2 cycles before:
        --! 1 clock cycle for fetching the configuration from the RAM
        --! 1 clock cycle to process it
        o_int_func_reg  : out picoevr_int_func;
    );
end entity;

architecture behaviour of evnt_dec_controller is

    type ctrl_state is (CLEAR, RISE);
    signal ctrl_cur, ctrl_next : ctrl_state := CLEAR;

    signal internal_func_reg,
           setxNrstx_prev     : std_logic_vector(31 downto 0) := (others = '0');
    signal pgen_ctrl_reg      : pgen_map_reg := (others => '0');

    -- Detect if there's at least 1 active bit in a register
    function hotbit (
            some_array : std_logic_vector
        )
        return std_logic is
        variable hot : std_logic := '0';
    begin
        for I in 0 to some_array'length-1 loop
            hot := some_array(I);
            exit when hot = '1';
        end loop;
        return hot;        
    end function hotbit;

begin

    -- FSM state update
    process (i_evnt_clk)
    begin
        if rising_edge(i_evnt_clk) then
            if i_reset = '1' then
                ctrl_cur <= CLEAR;
            else
                ctrl_cur <= ctrl_next;
            end if;
        end if;
    end process;

   -- FSM for the BRAM controller
   -- Only two stages: 1 stage for rising bits, 1 stage for clearing bits
   -- RISE stage might also need to clear some bits when events are received in 
   -- consecutive clock cycles.
    process(ctrl_cur, i_evnt_rdy)
        variable doreset : std_logic := '0';
    begin
        ctrl_next <= ctrl_cur;

        case ctrl_cur is
            when CLEAR   =>
                ctrl_busy <= '0';

                -- Clear bits risen in the previous step
                pgen_ctrl_reg.triggerx  <= (others => '0');
                internal_func           <= (others -> '0');
                -- Keeps previously SET bits, clears RESET bits from the previous step
                pgen_ctrl_reg.setxNrstx <= pgen_ctrl_reg.setxNrstx and setxNrstx_prev;
                -- Load the identity in case the next state is CLEAR in order to avoid clearing
                -- bits which shouldn't be cleared.
                setxNrstx_prev          <= pgen_ctrl_reg.setxNrstx and setxNrstx_prev;  

                if i_evnt_rdy = '1' then
                    ctrl_next <= RISE;
                else
                    ctrl_next <= CLEAR;
                end if;

            when RISE   =>
                -- The trigger flags register is safe to be overwritten with the new configuration value.
                -- Pulse Generators need only once clock cycle to detect an edge in this flags.
                pgen_ctrl_reg.triggerx <= i_evnt_cfg(c_EVR_MAP_TRI_HIGH-1 downto c_EVR_MAP_TRI_LOW);
                -- The received event resets any Pulse Generator?
                doreset := hotbit(i_evnt_cfg(c_EVR_MAP_RST_HIGH-1 downto c_EVR_MAP_RST_LOW));
                -- Do reset indicates that, at least, one PGen shall be reset. Clear the setNreset register
                -- using the active bits from the configuration word, field reset.
                -- WARNING: IF the target PGen was configured in counting mode, it will be reset in the next 
                --          clock cycle. Is this a problem?
                if doreset = '1' then
                    setxNrstx_prev          <= pgen_ctrl_reg.setxNrstx;
                    pgen_ctrl_reg.setxNrstx <= pgen_ctrl_reg.setxNrstx xor i_evnt_cfg(c_EVR_MAP_RST_HIGH-1 downto c_EVR_MAP_RST_LOW);
                end if;

                -- If a new SET bit has to be rised, just add it to the configuration register, 0 or X is X
                pgen_ctrl_reg.setxNrstx <= pgen_ctrl_reg.setxNrstx or i_evnt_cfg(c_EVR_MAP_SET_HIGH-1 downto c_EVR_MAP_SET_LOW);

                -- As it happens with the trigger flags, the internal function flags may be just overwritten
                -- with the new values
                internal_func_reg       <= i_evnt_cfg(c_EVNT_MAP_DATA_WIDTH-1 downto c_EVR_MAP_FUNC_SHIFT);            

                if i_evnt_rdy = '1' then
                    ctrl_next <= RISE;
                else
                    ctrl_next <= CLEAR;
                end if;
        end case;
    end process;

    process (i_evnt_clk)
    begin
        if rising_edge(i_evnt_clk) then
            o_int_func_reg <= internal_func_reg;
            o_pgen_map_reg <= pgen_ctrl_reg;
        end if;
    end process;

end architecture;