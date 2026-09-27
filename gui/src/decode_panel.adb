-- ***************************************************************************
--                ScopeBridge GUI - Bus Decoding Panel Body
--
--           Copyright (C) 2026 By Ulrik Hørlyk Hjort
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
-- LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
-- OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- ***************************************************************************

with Ada.Characters.Handling;  use Ada.Characters.Handling;
with Ada.Strings.Fixed;        use Ada.Strings.Fixed;

with GNATCOLL.JSON;            use GNATCOLL.JSON;

with Glib;                     use Glib;
with Gtk.Box;                  use Gtk.Box;
with Gtk.Button;               use Gtk.Button;
with Gtk.Cell_Renderer_Text;   use Gtk.Cell_Renderer_Text;
with Gtk.Check_Button;         use Gtk.Check_Button;
with Gtk.Combo_Box;            use Gtk.Combo_Box;
with Gtk.Combo_Box_Text;       use Gtk.Combo_Box_Text;
with Gtk.Enums;                use Gtk.Enums;
with Gtk.Grid;                 use Gtk.Grid;
with Gtk.Label;                use Gtk.Label;
with Gtk.List_Store;           use Gtk.List_Store;
with Gtk.Scrolled_Window;      use Gtk.Scrolled_Window;
with Gtk.Tree_Model;           use Gtk.Tree_Model;
with Gtk.Tree_Selection;       use Gtk.Tree_Selection;
with Gtk.Tree_View;            use Gtk.Tree_View;
with Gtk.Tree_View_Column;     use Gtk.Tree_View_Column;

with Server.Wire;
with Gui_Client;
with Scope_View;
with Units;                    use Units;
with Widgets;                  use Widgets;

package body Decode_Panel is

   Max_Items : constant := 50_000;   --  more would make the list slow

   Say_To, Fail_To : Reporter;

   Protocol_Box : Gtk_Combo_Box_Text;           --  UART, I2C, SPI
   UART_Box, I2C_Box, SPI_Box : Gtk_Grid;

   TX, RX, Baud, Bits, Parity, Stop : Gtk_Combo_Box_Text;
   UART_Inverted, UART_MSB           : Gtk_Check_Button;
   SCL                               : Gtk_Combo_Box_Text;
   Clock, Edge, Width, Timeout       : Gtk_Combo_Box_Text;
   SPI_LSB, SPI_Inverted             : Gtk_Check_Button;
   Format_Box                        : Gtk_Combo_Box_Text;

   Results   : Gtk_Vbox;
   Summary   : Gtk_Label;
   Store     : Gtk_List_Store;
   List      : Gtk_Tree_View;

   Shown     : Boolean := False;   --  items are decoded and shown

   --  List columns
   Col_Time  : constant := 0;
   Col_Ch    : constant := 1;
   Col_Type  : constant := 2;
   Col_Value : constant := 3;
   Col_Note  : constant := 4;
   Col_First : constant := 5;   --  hidden: the samples, for zooming
   Col_Last  : constant := 6;

   Formats : constant array (0 .. 3) of String (1 .. 5) :=
     ("hex  ", "ascii", "dec  ", "bin  ");

   function Format return String is
     (Trim (Formats (Integer'Max (0, Integer (Format_Box.Get_Active))),
            Ada.Strings.Right));

   function Protocol return String is
     (case Protocol_Box.Get_Active is
         when 1 => "i2c", when 2 => "spi", when others => "uart");

   --  Word width of the data, for binary and hex labels
   function Data_Bits return Positive is
     (if Protocol = "spi" then 8 * (1 + Natural'Max (0, Integer (Width.Get_Active)))
      elsif Protocol = "uart" then 5 + Natural'Max (0, Integer (Bits.Get_Active))
      else 8);

   --  "5u" -> 5.0e-6, "115200" -> 115200.0
   function Value_Of (Text : String) return Float is
      T      : constant String := Trim (Text, Ada.Strings.Both);
      Factor : Float := 1.0;
      Last   : Natural := T'Last;
   begin
      if T'Length > 1 then
         case T (T'Last) is
            when 'n' => Factor := 1.0E-9;
            when 'u' => Factor := 1.0E-6;
            when 'm' => Factor := 1.0E-3;
            when 'k' => Factor := 1.0E3;
            when 'M' => Factor := 1.0E6;
            when others => Last := T'Last + 1;
         end case;
         Last := Last - 1;
      end if;
      declare
         M : constant String := T (T'First .. Last);
      begin
         return Factor * Float'Value
           (if Index (M, ".") = 0 and then Index (To_Lower (M), "e") = 0
            then M & ".0" else M);
      end;
   end Value_Of;

   function Ch (Combo : Gtk_Combo_Box_Text) return Integer is
     (if Combo.Get_Active = 1 then 2 else 1);

   --  The protocol's settings, as "decode" and "set_decoder" take them;
   --  raises Constraint_Error for a baud rate or timeout that is no number
   function Settings return JSON_Value is
      M : constant JSON_Value := Create_Object;
   begin
      Set_Field (M, "protocol", Protocol);
      if Protocol = "uart" then
         Set_Field (M, "tx", Ch (TX));
         if RX.Get_Active > 0 then
            Set_Field (M, "rx", Integer (RX.Get_Active));
         end if;
         Set_Field (M, "baud", Integer (Value_Of (Baud.Get_Active_Text)));
         Set_Field (M, "bits", Data_Bits);
         Set_Field (M, "parity",
                    (case Parity.Get_Active is
                        when 1 => "even", when 2 => "odd", when others => "none"));
         Set_Field (M, "stop", Server.Wire.To_JSON
                      (case Stop.Get_Active is
                          when 1 => 1.5, when 2 => 2.0, when others => 1.0));
         Set_Field (M, "inverted", UART_Inverted.Get_Active);
         Set_Field (M, "msb_first", UART_MSB.Get_Active);
      elsif Protocol = "i2c" then
         Set_Field (M, "scl", Ch (SCL));
         Set_Field (M, "sda", 3 - Ch (SCL));
      else
         Set_Field (M, "clk", Ch (Clock));
         Set_Field (M, "data", 3 - Ch (Clock));
         Set_Field (M, "edge", (if Edge.Get_Active = 1 then "falling" else "rising"));
         Set_Field (M, "width", Data_Bits);
         Set_Field (M, "msb_first", not SPI_LSB.Get_Active);
         Set_Field (M, "inverted", SPI_Inverted.Get_Active);
         if To_Lower (Trim (Timeout.Get_Active_Text, Ada.Strings.Both)) /= "auto" then
            Set_Field (M, "timeout", Server.Wire.To_JSON (Value_Of (Timeout.Get_Active_Text)));
         end if;
      end if;
      return M;
   end Settings;

   -- -------------------------------------------------------------------------

   procedure On_Decoded (Reply : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
   begin
      if not Get (Reply, "ok") then
         Fail_To (Get (Reply, "error"));
         return;
      end if;
      declare
         Items : constant JSON_Array := Get (Reply, "items");
         Iter  : Gtk_Tree_Iter;
         Count : constant Integer := Get (Reply, "count");
      begin
         Scope_View.Set_Decoded (Items, Format, Data_Bits);
         --  Filled detached from the view, which is much faster
         List.Set_Model (Null_Gtk_Tree_Model);
         Store.Clear;
         for K in 1 .. Length (Items) loop
            declare
               It     : constant JSON_Value := Get (Items, K);
               Kind_S : constant String := Get (It, "type");
               Note   : constant String :=
                 (if Has_Field (It, "error") then String'(Get (It, "error")) & " error"
                  elsif Has_Field (It, "ack") then
                    (if Get (It, "ack") then "ack" else "no ack")
                  else "");
               Value  : constant Long_Integer :=
                 (if Has_Field (It, "value") then Get (It, "value") else 0);
            begin
               Store.Append (Iter);
               Store.Set (Iter, Col_Time, Eng (Float (Get_Long_Float (It, "t")), "s"));
               Store.Set (Iter, Col_Ch, "CH" & Trim (Integer'Image (Get (It, "ch")),
                                                     Ada.Strings.Left));
               Store.Set (Iter, Col_Type, Kind_S);
               Store.Set (Iter, Col_Value,
                          Scope_View.Item_Label (It, Format, Data_Bits) &
                          (if Kind_S = "data" and then Format /= "ascii"
                             and then Value in 32 .. 126
                           then "  '" & Character'Val (Value) & "'" else ""));
               Store.Set (Iter, Col_Note, Note);
               Store.Set (Iter, Col_First, Gint (Integer'(Get (It, "first"))));
               Store.Set (Iter, Col_Last, Gint (Integer'(Get (It, "last"))));
            end;
         end loop;
         List.Set_Model (+Store);
         Summary.Set_Text
           (Trim (Count'Image, Ada.Strings.Left) & " items, " & To_Upper (Protocol) &
            (if Get (Reply, "truncated") then " (the first" & Integer'Image (Max_Items) & ")"
             else "") &
            ";  thresholds" &
            (if Has_Field (Get (Reply, "thresholds"), "ch1")
             then " CH1 " & Eng (Float (Get_Long_Float (Get (Reply, "thresholds"), "ch1")), "V")
             else "") &
            (if Has_Field (Get (Reply, "thresholds"), "ch2")
             then " CH2 " & Eng (Float (Get_Long_Float (Get (Reply, "thresholds"), "ch2")), "V")
             else "") &
            ".  Choose an item to zoom to it.");
         Results.Show_All;
         Shown := True;
         Say_To ("Decoded" & Count'Image & " items");
      end;
   end On_Decoded;

   procedure Request_Decode is
      M : JSON_Value;
   begin
      if Scope_View."/=" (Scope_View.Mode, Scope_View.Capture) then
         Fail_To ("decoding works on a capture: press Capture memory first");
         return;
      end if;
      begin
         M := Settings;
      exception
         when Constraint_Error =>
            Fail_To ("the baud rate or timeout is not a number");
            return;
      end;
      Set_Field (M, "max_items", Integer'(Max_Items));
      Gui_Client.Request ("decode", M, On_Decoded'Access);
      Say_To ("Decoding ...");
   end Request_Decode;

   procedure On_Decode (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Request_Decode;
   end On_Decode;

   procedure On_Scope_Set (Reply : JSON_Value; Payload : String) is
      pragma Unreferenced (Payload);
   begin
      if Get (Reply, "ok") then
         Say_To ("The scope shows the bus (decoder 1)");
      else
         Fail_To (Get (Reply, "error"));
      end if;
   end On_Scope_Set;

   procedure On_Show_On_Scope (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
      M : JSON_Value;
   begin
      M := Settings;
      Set_Field (M, "bus", Integer'(1));
      Set_Field (M, "format", Format);
      Set_Field (M, "display", True);
      Gui_Client.Request ("set_decoder", M, On_Scope_Set'Access);
   exception
      when Constraint_Error =>
         Fail_To ("the baud rate or timeout is not a number");
   end On_Show_On_Scope;

   procedure On_Clear (Self : access Gtk_Button_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Shown := False;
      Store.Clear;
      Scope_View.Clear_Decoded;
      Results.Hide;
   end On_Clear;

   procedure Show_Protocol is
   begin
      UART_Box.Set_Visible (Protocol = "uart");
      I2C_Box.Set_Visible (Protocol = "i2c");
      SPI_Box.Set_Visible (Protocol = "spi");
   end Show_Protocol;

   procedure On_Protocol (Self : access Gtk_Combo_Box_Record'Class) is
      pragma Unreferenced (Self);
   begin
      Show_Protocol;
   end On_Protocol;

   --  The labels follow the format at once
   procedure On_Format (Self : access Gtk_Combo_Box_Record'Class) is
      pragma Unreferenced (Self);
   begin
      if Shown then
         Request_Decode;
      end if;
   end On_Format;

   procedure On_Select (Self : access Gtk_Tree_Selection_Record'Class) is
      Model : Gtk_Tree_Model;
      Iter  : Gtk_Tree_Iter;
   begin
      Self.Get_Selected (Model, Iter);
      if Iter /= Null_Iter then
         Scope_View.Zoom_To (Natural (Get_Int (Model, Iter, Col_First)),
                             Natural (Get_Int (Model, Iter, Col_Last)));
      end if;
   end On_Select;

   -- -------------------------------------------------------------------------

   function Grid return Gtk_Grid is
      G : constant Gtk_Grid := Row_Grid;
   begin
      G.Set_Row_Spacing (4);
      G.Set_Column_Spacing (8);
      return G;
   end Grid;

   function Create_Controls (Say, Fail : Reporter) return Gtk_Widget is
      G : constant Gtk_Grid := Row_Grid;
      Timeouts : constant array (1 .. 6) of String (1 .. 5) :=
        ("auto ", "1u   ", "2u   ", "5u   ", "10u  ", "100u ");
   begin
      Say_To  := Say;
      Fail_To := Fail;

      Protocol_Box := New_Combo ("UART|I2C|SPI");
      Protocol_Box.Set_Active (0);
      G.Attach (New_Label ("Protocol"), 0, 0);
      G.Attach (Protocol_Box, 1, 0);

      UART_Box := Grid;
      TX       := New_Combo ("CH1|CH2");
      RX       := New_Combo ("none|CH1|CH2");
      Gtk_New_With_Entry (Baud);
      for B of Units.Float_Array'(1200.0, 2400.0, 4800.0, 9600.0, 19_200.0, 38_400.0,
                                  57_600.0, 115_200.0, 230_400.0, 460_800.0,
                                  921_600.0, 1_000_000.0)
      loop
         Baud.Append_Text (Trim (Integer'Image (Integer (B)), Ada.Strings.Left));
      end loop;
      Bits     := New_Combo ("5|6|7|8|9");
      Parity   := New_Combo ("none|even|odd");
      Stop     := New_Combo ("1|1.5|2");
      Gtk_New (UART_Inverted, "Idle low");
      Gtk_New (UART_MSB, "MSB first");
      TX.Set_Active (0);
      RX.Set_Active (0);
      Baud.Set_Active (3);   --  9600
      Bits.Set_Active (3);   --  8
      Parity.Set_Active (0);
      Stop.Set_Active (0);
      UART_Box.Attach (New_Label ("TX"), 0, 0);
      UART_Box.Attach (TX, 1, 0);
      UART_Box.Attach (New_Label ("RX"), 0, 1);
      UART_Box.Attach (RX, 1, 1);
      UART_Box.Attach (New_Label ("Baud"), 0, 2);
      UART_Box.Attach (Baud, 1, 2);
      UART_Box.Attach (New_Label ("Data bits"), 0, 3);
      UART_Box.Attach (Bits, 1, 3);
      UART_Box.Attach (New_Label ("Parity"), 0, 4);
      UART_Box.Attach (Parity, 1, 4);
      UART_Box.Attach (New_Label ("Stop bits"), 0, 5);
      UART_Box.Attach (Stop, 1, 5);
      UART_Box.Attach (UART_Inverted, 0, 6);
      UART_Box.Attach (UART_MSB, 1, 6);
      G.Attach (UART_Box, 0, 1, 2);

      I2C_Box := Grid;
      SCL     := New_Combo ("CH1|CH2");
      SCL.Set_Active (0);
      I2C_Box.Attach (New_Label ("SCL"), 0, 0);
      I2C_Box.Attach (SCL, 1, 0);
      I2C_Box.Attach (New_Label ("SDA is the other channel"), 0, 1, 2);
      G.Attach (I2C_Box, 0, 2, 2);

      SPI_Box := Grid;
      Clock   := New_Combo ("CH1|CH2");
      Edge    := New_Combo ("rising edge|falling edge");
      Width   := New_Combo ("8 bits|16 bits|24 bits|32 bits");
      Gtk_New_With_Entry (Timeout);
      for T of Timeouts loop
         Timeout.Append_Text (Trim (T, Ada.Strings.Right));
      end loop;
      Gtk_New (SPI_LSB, "LSB first");
      Gtk_New (SPI_Inverted, "Data active low");
      Clock.Set_Active (0);
      Edge.Set_Active (0);
      Width.Set_Active (0);
      Timeout.Set_Active (0);
      SPI_Box.Attach (New_Label ("Clock"), 0, 0);
      SPI_Box.Attach (Clock, 1, 0);
      SPI_Box.Attach (New_Label ("Data valid on"), 0, 1);
      SPI_Box.Attach (Edge, 1, 1);
      SPI_Box.Attach (New_Label ("Word"), 0, 2);
      SPI_Box.Attach (Width, 1, 2);
      SPI_Box.Attach (New_Label ("Timeout"), 0, 3);
      SPI_Box.Attach (Timeout, 1, 3);
      SPI_Box.Attach (SPI_LSB, 0, 4);
      SPI_Box.Attach (SPI_Inverted, 1, 4);
      SPI_Box.Attach (New_Label ("Data is the other channel"), 0, 5, 2);
      G.Attach (SPI_Box, 0, 3, 2);

      Format_Box := New_Combo ("Hex|ASCII|Decimal|Binary");
      Format_Box.Set_Active (0);
      G.Attach (New_Label ("Show as"), 0, 4);
      G.Attach (Format_Box, 1, 4);
      G.Attach (New_Button ("Decode capture", On_Decode'Access), 0, 5);
      G.Attach (New_Button ("Show on scope", On_Show_On_Scope'Access), 1, 5);
      G.Attach (New_Button ("Clear", On_Clear'Access), 0, 6);

      Protocol_Box.On_Changed (On_Protocol'Access);
      Format_Box.On_Changed (On_Format'Access);
      return Gtk_Widget (Framed ("Decode", G));
   end Create_Controls;

   function Create_Results return Gtk_Widget is
      Scroll : Gtk_Scrolled_Window;
      Titles : constant array (Col_Time .. Col_Note) of String (1 .. 5) :=
        ("Time ", "Ch   ", "Type ", "Value", "     ");
      Dummy  : Gint;
   begin
      Gtk_New_Vbox (Results, Spacing => 2);
      Summary := New_Label ("");
      Results.Pack_Start (Summary, Expand => False);
      Gtk_New (Store, (Col_Time .. Col_Note => GType_String,
                       Col_First | Col_Last => GType_Int));
      Gtk_New (List, +Store);
      for C in Titles'Range loop
         declare
            Column : Gtk_Tree_View_Column;
            Cell   : Gtk_Cell_Renderer_Text;
         begin
            Gtk_New (Column);
            Column.Set_Title (Trim (Titles (C), Ada.Strings.Right));
            Gtk_New (Cell);
            Column.Pack_Start (Cell, True);
            Column.Add_Attribute (Cell, "text", Gint (C));
            Dummy := List.Append_Column (Column);
         end;
      end loop;
      List.Get_Selection.On_Changed (On_Select'Access);
      Gtk_New (Scroll);
      Scroll.Set_Policy (Policy_Never, Policy_Automatic);
      Scroll.Set_Size_Request (-1, 150);
      Scroll.Add (List);
      Results.Pack_Start (Scroll, Expand => True, Fill => True);
      return Gtk_Widget (Results);
   end Create_Results;

   procedure After_Show is
   begin
      Show_Protocol;
      if not Shown then
         Results.Hide;
      end if;
   end After_Show;

   procedure Captured is
   begin
      if Shown then
         Request_Decode;
      end if;
   end Captured;

end Decode_Panel;
