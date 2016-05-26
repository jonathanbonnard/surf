-------------------------------------------------------------------------------
-- Title      : 
-------------------------------------------------------------------------------
-- File       : RawEthFramerRx.vhd
-- Author     : Larry Ruckman  <ruckman@slac.stanford.edu>
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2016-05-23
-- Last update: 2016-05-25
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description: 
-------------------------------------------------------------------------------
-- This file is part of 'SLAC Ethernet Library'.
-- It is subject to the license terms in the LICENSE.txt file found in the 
-- top-level directory of this distribution and at: 
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html. 
-- No part of 'SLAC Ethernet Library', including this file, 
-- may be copied, modified, propagated, or distributed except according to 
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.SsiPkg.all;
use work.EthMacPkg.all;

entity RawEthFramerRx is
   generic (
      TPD_G         : time             := 1 ns;
      REMOTE_SIZE_G : positive         := 1;
      ETH_TYPE_G    : slv(15 downto 0) := x"0010");            --  0x1000 (big-Endian configuration)
   port (
      -- Local Configurations
      localMac    : in  slv(47 downto 0);                      --  big-Endian configuration
      remoteMac   : in  Slv48Array(REMOTE_SIZE_G-1 downto 0);  --  big-Endian configuration
      -- Interface to Ethernet Media Access Controller (MAC)
      obMacMaster : in  AxiStreamMasterType;
      obMacSlave  : out AxiStreamSlaveType;
      -- Interface to Application engine(s)
      ibAppMaster : out AxiStreamMasterType;
      ibAppSlave  : in  AxiStreamSlaveType;
      -- Clock and Reset
      clk         : in  sl;
      rst         : in  sl);
end RawEthFramerRx;

architecture rtl of RawEthFramerRx is

   type StateType is (
      IDLE_S,
      HDR_S,
      SCAN_S,
      MOVE_S);

   type RegType is record
      index       : natural range 0 to REMOTE_SIZE_G-1;
      srcMac      : slv(47 downto 0);
      minByteCnt  : natural range 0 to 127;
      sof         : sl;
      eof         : sl;
      eofe        : sl;
      obMacSlave  : AxiStreamSlaveType;
      ibAppMaster : AxiStreamMasterType;
      state       : StateType;
   end record RegType;
   constant REG_INIT_C : RegType := (
      index       => 0,
      srcMac      => (others => '0'),
      minByteCnt  => 0,
      sof         => '1',
      eof         => '0',
      eofe        => '0',
      obMacSlave  => AXI_STREAM_SLAVE_INIT_C,
      ibAppMaster => AXI_STREAM_MASTER_INIT_C,
      state       => IDLE_S);

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

   -- attribute dont_touch             : string;
   -- attribute dont_touch of r        : signal is "TRUE";

begin

   comb : process (ibAppSlave, localMac, obMacMaster, r, remoteMac, rst) is
      variable v : RegType;
   begin
      -- Latch the current value
      v := r;

      -- Reset the flags
      v.obMacSlave := AXI_STREAM_SLAVE_INIT_C;
      if ibAppSlave.tReady = '1' then
         v.ibAppMaster.tValid := '0';
         v.ibAppMaster.tLast  := '0';
         v.ibAppMaster.tUser  := (others => '0');
         v.ibAppMaster.tKeep  := x"00FF";
      end if;

      -- State Machine
      case r.state is
         ----------------------------------------------------------------------
         when IDLE_S =>
            -- Check for data
            if (obMacMaster.tValid = '1') then
               -- Accept the data
               v.obMacSlave.tReady   := '1';
               -- Latch the SRC MAC
               v.srcMac(15 downto 0) := obMacMaster.tData(63 downto 48);
               -- Check for SOF
               if (ssiGetUserSof(EMAC_AXIS_CONFIG_C, obMacMaster) = '1') then
                  -- Check the DEST MAC
                  if (localMac /= 0) and (localMac = obMacMaster.tData(47 downto 0)) then
                     -- Next state
                     v.state := HDR_S;
                  end if;
               end if;
            end if;
         ----------------------------------------------------------------------
         when HDR_S =>
            -- Check for data
            if (obMacMaster.tValid = '1') then
               -- Accept the data
               v.obMacSlave.tReady    := '1';
               -- Latch the SRC MAC
               v.srcMac(47 downto 16) := obMacMaster.tData(31 downto 0);
               -- Get the min. byte cache count
               v.minByteCnt           := conv_integer(obMacMaster.tData(54 downto 48));
               -- Check for invalid size or invalid EtherType
               if (obMacMaster.tData(63 downto 55) /= 0) or (v.minByteCnt > 64) or (obMacMaster.tData(47 downto 32) /= ETH_TYPE_G) then
                  -- Next state
                  v.state := IDLE_S;
               else
                  -- Next state
                  v.state := SCAN_S;
               end if;
            end if;
         ----------------------------------------------------------------------
         when SCAN_S =>
            -- Check the DEST MAC
            if (remoteMac(r.index) /= 0) and (remoteMac(r.index) = r.srcMac) then
               -- Reset the flag
               v.sof := '1';
               if r.minByteCnt = 0 then
                  v.eof := '0';
               else
                  v.eof        := '1';
                  -- Remove the header offset
                  v.minByteCnt := r.minByteCnt - 16;
               end if;
               -- Set the destination
               v.ibAppMaster.tDest := toSlv(r.index, 8);
               -- Next state
               v.state             := MOVE_S;
            else
               -- Check the counter
               if r.index = (REMOTE_SIZE_G-1) then
                  -- Reset the counter
                  v.index := 0;
                  -- Next state
                  v.state := IDLE_S;
               else
                  -- Increment the counter
                  v.index := r.index + 1;
               end if;
            end if;
         ----------------------------------------------------------------------
         when MOVE_S =>
            -- Check if ready to move data
            if (obMacMaster.tValid = '1') and (v.ibAppMaster.tValid = '0') then
               -- Accept the data
               v.obMacSlave.tReady              := '1';
               -- Move the data
               v.ibAppMaster.tValid             := '1';
               v.ibAppMaster.tData(63 downto 0) := obMacMaster.tData(63 downto 0);
               v.ibAppMaster.tKeep(7 downto 0)  := obMacMaster.tKeep(7 downto 0);
               -- Check for SOF
               if r.sof = '1' then
                  -- Reset the flag
                  v.sof := '0';
                  -- Set the SOF
                  ssiSetUserSof(EMAC_AXIS_CONFIG_C, v.ibAppMaster, '1');
               end if;
               -- Get EOFE
               v.eofe := ssiGetUserEofe(EMAC_AXIS_CONFIG_C, obMacMaster);
               -- Check for tLast
               if obMacMaster.tLast = '1' then
                  -- Set EOF
                  v.ibAppMaster.tLast := '1';
                  -- Set the EOFE
                  ssiSetUserEofe(EMAC_AXIS_CONFIG_C, v.ibAppMaster, v.eofe);
                  -- Next state
                  v.state             := IDLE_S;
               end if;
               -- Check if TX engine had min. ETH cache
               if r.eof = '1' then
                  -- Check for last transfer
                  if (r.minByteCnt <= 8) then
                     -- Update tKeep
                     v.ibAppMaster.tKeep := genTKeep(r.minByteCnt);
                     -- Set EOF
                     v.ibAppMaster.tLast := '1';
                     -- Set the EOFE
                     ssiSetUserEofe(EMAC_AXIS_CONFIG_C, v.ibAppMaster, v.eofe);
                     -- Next state
                     v.state             := IDLE_S;
                  else
                     -- Decrement the counter
                     v.minByteCnt := r.minByteCnt - 8;
                  end if;
               end if;
            end if;
      ----------------------------------------------------------------------
      end case;

      -- Reset
      if (rst = '1') then
         v := REG_INIT_C;
      end if;

      -- Register the variable for next clock cycle
      rin <= v;

      -- Outputs        
      obMacSlave  <= v.obMacSlave;
      ibAppMaster <= r.ibAppMaster;

   end process comb;

   seq : process (clk) is
   begin
      if rising_edge(clk) then
         r <= rin after TPD_G;
      end if;
   end process seq;

end rtl;