-------------------------------------------------------------------------------
-- File       : AxiStreamDmaFifo.vhd
-- Company    : SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
-- Description:
-- Generic AXI Stream FIFO DMA block for frame at a time transfers.
-------------------------------------------------------------------------------
-- This file is part of 'SLAC Firmware Standard Library'.
-- It is subject to the license terms in the LICENSE.txt file found in the 
-- top-level directory of this distribution and at: 
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html. 
-- No part of 'SLAC Firmware Standard Library', including this file, 
-- may be copied, modified, propagated, or distributed except according to 
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.AxiPkg.all;
use work.AxiDmaPkg.all;

entity AxiStreamDmaFifo is
   generic (
      TPD_G              : time                := 1 ns;
      -- FIFO Configuration
      MAX_FRAME_WIDTH_G  : positive            := 14;  -- Maximum AXI Stream frame size (units of address bits)
      AXI_BUFFER_WIDTH_G : positive            := 28;  -- Total AXI Memory for FIFO buffering (units of address bits)
      DROP_ERR_FRAME_G   : boolean             := false;
      -- AXI Stream Configurations
      AXIS_CONFIG_G      : AxiStreamConfigType := AXIS_WRITE_DMA_CONFIG_C;
      -- AXI4 Configurations
      AXI_BASE_ADDR_G    : slv(63 downto 0)    := x"0000_0000_0000_0000";  -- Memory Base Address Offset
      AXI_CONFIG_G       : AxiConfigType       := axiConfig(32, 8, 4, 4);
      AXI_BURST_G        : slv(1 downto 0)     := "01";
      AXI_CACHE_G        : slv(3 downto 0)     := "1111");
   port (
      clk            : in  sl;
      rst            : in  sl;
      -- AXI Stream Interface
      sAxisMaster    : in  AxiStreamMasterType;
      sAxisSlave     : out AxiStreamSlaveType;
      mAxisMaster    : out AxiStreamMasterType;
      mAxisSlave     : in  AxiStreamSlaveType;
      -- AXI4 Interface
      axiReadMaster  : out AxiReadMasterType;
      axiReadSlave   : in  AxiReadSlaveType;
      axiWriteMaster : out AxiWriteMasterType;
      axiWriteSlave  : in  AxiWriteSlaveType);
end AxiStreamDmaFifo;

architecture rtl of AxiStreamDmaFifo is

   constant BYP_SHIFT_C : boolean := true;  -- APP DMA driver enforces alignment, which means shift not required

   constant BIT_DIFF_C     : positive := AXI_BUFFER_WIDTH_G-MAX_FRAME_WIDTH_G;
   constant ADDR_WIDTH_C   : positive := ite((BIT_DIFF_C <= 9), BIT_DIFF_C, 9);
   constant CASCADE_SIZE_C : positive := ite((BIT_DIFF_C <= 9), 1, 2**(BIT_DIFF_C-9));

   constant TDEST_BITS_C : positive := ite(AXIS_CONFIG_G.TDEST_BITS_C = 0, 1, AXIS_CONFIG_G.TDEST_BITS_C);
   constant TID_BITS_C   : positive := ite(AXIS_CONFIG_G.TID_BITS_C = 0, 1, AXIS_CONFIG_G.TID_BITS_C);
   constant TUSER_BITS_C : positive := ite(AXIS_CONFIG_G.TUSER_BITS_C = 0, 1, AXIS_CONFIG_G.TUSER_BITS_C);

   type RegType is record
      rdQueueReady : sl;
      wrQueueValid : sl;
      wrQueueData  : slv(AXI_READ_DMA_READ_REQ_SIZE_C-1 downto 0);
      wrIndex      : slv(BIT_DIFF_C-1 downto 0);
      rdIndex      : slv(BIT_DIFF_C-1 downto 0);
      wrReq        : AxiWriteDmaReqType;
      rdReq        : AxiReadDmaReqType;
   end record RegType;
   constant REG_INIT_C : RegType := (
      rdQueueReady => '0',
      wrQueueValid => '0',
      wrQueueData  => (others => '0'),
      wrIndex      => (others => '0'),
      rdIndex      => (others => '0'),
      wrReq        => AXI_WRITE_DMA_REQ_INIT_C,
      rdReq        => AXI_READ_DMA_REQ_INIT_C);

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

   signal wrAck : AxiWriteDmaAckType;
   signal rdAck : AxiReadDmaAckType;

   signal wrQueueAfull : sl;
   signal rdQueueValid : sl;
   signal rdQueueReady : sl;
   signal rdQueueData  : slv(AXI_READ_DMA_READ_REQ_SIZE_C-1 downto 0);

begin

   assert (MAX_FRAME_WIDTH_G >= 12)     -- 4kB alignment
      report "MAX_FRAME_WIDTH_G must >= 12" severity failure;

   assert (AXI_BUFFER_WIDTH_G > MAX_FRAME_WIDTH_G)
      report "AXI_BUFFER_WIDTH_G must greater than MAX_FRAME_WIDTH_G" severity failure;

   ---------------------
   -- Inbound Controller
   ---------------------
   U_IbDma : entity work.AxiStreamDmaWrite
      generic map (
         TPD_G          => TPD_G,
         AXI_READY_EN_G => true,
         AXIS_CONFIG_G  => AXIS_CONFIG_G,
         AXI_CONFIG_G   => AXI_CONFIG_G,
         AXI_BURST_G    => AXI_BURST_G,
         AXI_CACHE_G    => AXI_CACHE_G,
         SW_CACHE_EN_G  => true,
         BYP_SHIFT_G    => BYP_SHIFT_C)
      port map (
         axiClk         => clk,
         axiRst         => rst,
         dmaReq         => r.wrReq,
         dmaAck         => wrAck,
         swCache        => AXI_CACHE_G,
         axisMaster     => sAxisMaster,
         axisSlave      => sAxisSlave,
         axiWriteMaster => axiWriteMaster,
         axiWriteSlave  => axiWriteSlave);

   ----------------------
   -- Outbound Controller
   ----------------------
   U_ObDma : entity work.AxiStreamDmaRead
      generic map (
         TPD_G           => TPD_G,
         AXIS_READY_EN_G => true,
         AXIS_CONFIG_G   => AXIS_CONFIG_G,
         AXI_CONFIG_G    => AXI_CONFIG_G,
         AXI_BURST_G     => AXI_BURST_G,
         AXI_CACHE_G     => AXI_CACHE_G,
         SW_CACHE_EN_G   => true,
         PEND_THRESH_G   => 0,
         BYP_SHIFT_G     => BYP_SHIFT_C)
      port map (
         axiClk        => clk,
         axiRst        => rst,
         dmaReq        => r.rdReq,
         dmaAck        => rdAck,
         swCache       => AXI_CACHE_G,
         axisMaster    => mAxisMaster,
         axisSlave     => mAxisSlave,
         axisCtrl      => AXI_STREAM_CTRL_UNUSED_C,
         axiReadMaster => axiReadMaster,
         axiReadSlave  => axiReadSlave);

   -------------
   -- Read Queue
   -------------
   U_ReadQueue : entity work.FifoCascade
      generic map (
         TPD_G           => TPD_G,
         FWFT_EN_G       => true,
         GEN_SYNC_FIFO_G => true,
         BRAM_EN_G       => true,
         DATA_WIDTH_G    => AXI_READ_DMA_READ_REQ_SIZE_C,
         CASCADE_SIZE_G  => CASCADE_SIZE_C,
         ADDR_WIDTH_G    => ADDR_WIDTH_C)
      port map (
         rst         => rst,
         -- Write Interface
         wr_clk      => clk,
         wr_en       => r.wrQueueValid,
         almost_full => wrQueueAfull,
         din         => r.wrQueueData,
         -- Read Interface
         rd_clk      => clk,
         valid       => rdQueueValid,
         rd_en       => rdQueueReady,
         dout        => rdQueueData);

   comb : process (r, rdAck, rdQueueData, rdQueueValid, rst, wrAck,
                   wrQueueAfull) is
      variable v        : RegType;
      variable varRdReq : AxiReadDmaReqType;
   begin
      -- Latch the current value
      v := r;

      -- Init() variables
      varRdReq := AXI_READ_DMA_REQ_INIT_C;

      -- Reset flags
      v.wrQueueValid := '0';
      v.rdQueueReady := '0';

      -- Set base address offset
      v.wrReq.address  := AXI_BASE_ADDR_G;
      varRdReq.address := AXI_BASE_ADDR_G;

      -- Update the address with respect to buffer index
      v.wrReq.address(AXI_BUFFER_WIDTH_G-1 downto MAX_FRAME_WIDTH_G)  := r.wrIndex;
      varRdReq.address(AXI_BUFFER_WIDTH_G-1 downto MAX_FRAME_WIDTH_G) := r.wrIndex;

      -- Set the max buffer size
      v.wrReq.maxSize := toSlv(2**MAX_FRAME_WIDTH_G, 32);

      --------------------------------------------------------------------------------

      -- Check if ready for next DMA Write REQ
      if (wrQueueAfull = '0') and (r.wrReq.request = '0') and (wrAck.done = '0') then

         -- Send the DMA Write REQ
         v.wrReq.request := '1';

      -- Wait for the DMA Write ACK
      elsif (r.wrReq.request = '1') and (wrAck.done = '1') then

         -- Reset the flag
         v.wrReq.request := '0';

         -- Generate the DMA READ REQ
         varRdReq.size                               := wrAck.size;
         varRdReq.firstUser(TUSER_BITS_C-1 downto 0) := wrAck.firstUser(TUSER_BITS_C-1 downto 0);
         varRdReq.lastUser(TUSER_BITS_C-1 downto 0)  := wrAck.lastUser(TUSER_BITS_C-1 downto 0);
         varRdReq.dest(TDEST_BITS_C-1 downto 0)      := wrAck.dest(TDEST_BITS_C-1 downto 0);
         varRdReq.id(TID_BITS_C-1 downto 0)          := wrAck.id(TID_BITS_C-1 downto 0);

         -- Set EOFE if error detected
         varRdReq.lastUser(0) := wrAck.overflow or wrAck.writeError;

         -- Forward the DMA READ REQ into the read queue
         v.wrQueueValid := '1';
         v.wrQueueData  := toSlv(varRdReq);

         -- Increment the write index
         v.wrIndex := r.wrIndex + 1;

         -- Check if we drop error AXI stream frames
         if DROP_ERR_FRAME_G and (varRdReq.lastUser(0) = '1') then

            -- Prevent the DMA READ REQ from going into the read queue
            v.wrQueueValid := '0';

            -- Keep the write index
            v.wrIndex := r.wrIndex;

         end if;

      end if;

      --------------------------------------------------------------------------------

      -- Check if ready for next DMA READ REQ
      if (rdQueueValid = '1') and (r.rdReq.request = '0') and (rdAck.done = '0') then

         -- Accept the FIFO data
         v.rdQueueReady := '1';

         -- Send the DMA Read REQ         
         v.rdReq := toAxiReadDmaReq(rdQueueData, '1');

      -- Wait for the DMA READ ACK
      elsif (r.rdReq.request = '1') and (rdAck.done = '1') then

         -- Reset the flag
         v.rdReq.request := '0';

         -- Increment the read index
         v.rdIndex := r.rdIndex + 1;

      end if;

      --------------------------------------------------------------------------------

      -- Outputs
      rdQueueReady <= v.rdQueueReady;

      -- Reset
      if (rst = '1') then
         v := REG_INIT_C;
      end if;

      -- Register the variable for next clock cycle
      rin <= v;

   end process comb;

   seq : process (clk) is
   begin
      if rising_edge(clk) then
         r <= rin after TPD_G;
      end if;
   end process seq;

end rtl;