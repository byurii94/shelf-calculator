# frozen_string_literal: true

require 'json'

module ShelfCalculator
  VERSION = "1.0.1"
  REMOTE_BASE_URL = "https://raw.githubusercontent.com/byurii94/shelf-calculator/main"

  def self.parse_float(val)
    return val.to_f if val.is_a?(Numeric)
    val.to_s.tr(',', '.').to_f
  end

  def self.parse_int(val)
    return val.to_i if val.is_a?(Numeric)
    val.to_s.tr(',', '.').to_i
  end

  def self.version_newer?(remote, local)
    r_parts = remote.split('.').map(&:to_i)
    l_parts = local.split('.').map(&:to_i)
    (r_parts <=> l_parts) == 1
  end

  def self.check_for_updates(silent: true)
    req = Sketchup::Http::Request.new("#{REMOTE_BASE_URL}/version.json", Sketchup::Http::GET)
    req.start do |_request, response|
      if response && response.status_code == 200
        begin
          data = JSON.parse(response.body)
          remote_ver = data["version"].to_s.strip
          if !remote_ver.empty? && version_newer?(remote_ver, VERSION)
            download_and_install_update(remote_ver)
          elsif !silent
            UI.messagebox("У вас уже встановлена актуальна версія (#{VERSION}).")
          end
        rescue => e
          UI.messagebox("Помилка перевірки оновлень: #{e.message}") unless silent
        end
      elsif !silent
        UI.messagebox("Не вдалося з'єднатися із сервером оновлень.")
      end
    end
  end

  def self.download_and_install_update(new_version)
    plugin_dir = File.dirname(__FILE__)
    files = ["main.rb", "dialog.html"]
    downloaded = {}
    pending = files.length
    failed = false

    files.each do |fname|
      file_req = Sketchup::Http::Request.new("#{REMOTE_BASE_URL}/#{fname}", Sketchup::Http::GET)
      file_req.start do |_r, resp|
        next if failed
        if resp && resp.status_code == 200 && !resp.body.to_s.empty?
          downloaded[fname] = resp.body
        else
          failed = true
          UI.messagebox("Не вдалося завантажити файл #{fname}.")
        end

        pending -= 1
        if pending == 0 && !failed
          downloaded.each do |name, content|
            File.binwrite(File.join(plugin_dir, name), content)
          end
          UI.messagebox(
            "Калькулятор полиць оновлено до версії #{new_version}!\n" \
            "Перезапустіть SketchUp, щоб зміни набули чинності."
          )
        end
      end
    end
  end

  class ShelfEdgeTool
    def initialize(group, dims_mm)
      @group = group
      @bb = group&.bounds
      @dims_mm = dims_mm
      @hover_axis = nil
      @hover_edge_pts = nil
      @selected_axis = nil
      @dialog = nil
      @gaps_mm = []
      @generated = false
      @prev_transparency = nil
      @params = {
        thickness: 18.0,
        num_items: 4
      }
    end

    def activate
      @selected_axis = nil
      @hover_axis = nil
      @hover_edge_pts = nil
      @generated = false

      opts = Sketchup.active_model.rendering_options
      @prev_transparency = opts["ModelTransparency"]
      opts["ModelTransparency"] = true

      Sketchup.set_status_text("🪵 КАЛЬКУЛЯТОР ПОЛИЦЬ | Наведіть курсор на ребро боксу та клікніть, щоб обрати напрямок розбиття | ESC = Вихід")
      Sketchup.active_model.active_view&.invalidate
    end

    def deactivate(view)
      close_dialog
      unless @prev_transparency.nil?
        Sketchup.active_model.rendering_options["ModelTransparency"] = @prev_transparency
        @prev_transparency = nil
      end
      view.invalidate if view
    end

    def onKeyDown(key, repeat, flags, view)
      if key == 27
        close_dialog
        Sketchup.active_model.select_tool(nil)
      end
    end

    def onMouseMove(flags, x, y, view)
      return if @selected_axis
      return unless @group && @group.valid? && @bb

      ip = view.inputpoint(x, y)
      edge = ip.edge

      if edge && edge_belongs_to_group?(edge, @group)
        tr = @group.transformation
        p1 = edge.start.position.transform(tr)
        p2 = edge.end.position.transform(tr)
        vec = p2 - p1

        if vec.length > 1e-6
          @hover_axis = vector_to_axis(vec.normalize)
          @hover_edge_pts = [p1, p2]
          Sketchup.set_status_text("🪵 Ребро вздовж осі [ #{axis_label(@hover_axis)} ] (#{axis_length_mm(@hover_axis).round(1)} мм) — клікніть для налаштувань | ESC = Вихід")
          view.invalidate
          return
        end
      end

      @hover_axis = nil
      @hover_edge_pts = nil
      Sketchup.set_status_text("🪵 Наведіть курсор на ребро виділеного боксу та клікніть | ESC = Вихід")
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      return if @selected_axis
      return unless @hover_axis

      @selected_axis = @hover_axis
      @params = {
        thickness: 18.0,
        num_items: 4
      }
      @gaps_mm = default_equal_gaps(axis_length_mm(@selected_axis), @params[:num_items], @params[:thickness])
      open_dialog
      view.invalidate
    end

    def draw(view)
      return unless @bb && @group&.valid?

      if @selected_axis.nil? && @hover_edge_pts && @hover_edge_pts.length == 2
        view.drawing_color = Sketchup::Color.new(40, 185, 65)
        view.line_width = 8
        view.draw(GL_LINES, @hover_edge_pts)
        return
      end

      return unless @selected_axis
      return unless valid_layout?

      view.drawing_color = Sketchup::Color.new(0, 120, 215)
      view.line_width = 2
      points = []

      start_x = @bb.min.x
      start_y = @bb.min.y
      start_z = @bb.min.z

      w_mm = @dims_mm[:width]
      d_mm = @dims_mm[:depth]
      h_mm = @dims_mm[:height]
      t_mm = @params[:thickness]

      case @selected_axis
      when :z
        cursor_z = @gaps_mm[0]
        @params[:num_items].times do |i|
          z0 = start_z + cursor_z.mm
          z1 = z0 + t_mm.mm
          points.concat(box_wireframe_points(
            start_x, start_y, z0,
            start_x + w_mm.mm, start_y + d_mm.mm, z1
          ))
          cursor_z += t_mm + @gaps_mm[i + 1]
        end

      when :x
        cursor_x = @gaps_mm[0]
        @params[:num_items].times do |i|
          x0 = start_x + cursor_x.mm
          x1 = x0 + t_mm.mm
          points.concat(box_wireframe_points(
            x0, start_y, start_z,
            x1, start_y + d_mm.mm, start_z + h_mm.mm
          ))
          cursor_x += t_mm + @gaps_mm[i + 1]
        end

      when :y
        cursor_y = @gaps_mm[0]
        @params[:num_items].times do |i|
          y0 = start_y + cursor_y.mm
          y1 = y0 + t_mm.mm
          points.concat(box_wireframe_points(
            start_x, y0, start_z,
            start_x + w_mm.mm, y1, start_z + h_mm.mm
          ))
          cursor_y += t_mm + @gaps_mm[i + 1]
        end
      end

      view.draw(GL_LINES, points) unless points.empty?
    end

    private

    def edge_belongs_to_group?(edge, group)
      return false unless edge.parent.is_a?(Sketchup::ComponentDefinition)
      group.entities.grep(Sketchup::Edge).include?(edge)
    end

    def vector_to_axis(vec)
      ax = vec.x.abs
      ay = vec.y.abs
      az = vec.z.abs
      if az >= ax && az >= ay
        :z
      elsif ax >= ay && ax >= az
        :x
      else
        :y
      end
    end

    def axis_label(axis)
      case axis
      when :z then "ВИСОТА (Z — горизонтальні полиці)"
      when :x then "ШИРИНА (X — перегородки по ширині)"
      when :y then "ГЛИБИНА (Y — перегородки по глибині)"
      else ""
      end
    end

    def axis_length_mm(axis)
      case axis
      when :z then @dims_mm[:height]
      when :x then @dims_mm[:width]
      when :y then @dims_mm[:depth]
      else 0.0
      end
    end

    def default_equal_gaps(total_len, num_items, thickness)
      num_gaps = num_items + 1
      free_len = total_len - (num_items * thickness)
      each_gap = free_len / num_gaps.to_f
      Array.new(num_gaps) { each_gap.round(2) }
    end

    def valid_layout?
      return false unless @group && @group.valid?
      n = @params[:num_items]
      t = @params[:thickness]
      return false if n <= 0 || t <= 0
      return false unless @gaps_mm.is_a?(Array) && @gaps_mm.length == n + 1
      return false if @gaps_mm.any? { |g| g.nil? || g < 0 }

      total_used = (n * t) + @gaps_mm.sum
      total_len = axis_length_mm(@selected_axis)
      total_used <= total_len + 0.01
    end

    def box_wireframe_points(x0, y0, z0, x1, y1, z1)
      p1 = Geom::Point3d.new(x0, y0, z0)
      p2 = Geom::Point3d.new(x1, y0, z0)
      p3 = Geom::Point3d.new(x1, y1, z0)
      p4 = Geom::Point3d.new(x0, y1, z0)

      p5 = Geom::Point3d.new(x0, y0, z1)
      p6 = Geom::Point3d.new(x1, y0, z1)
      p7 = Geom::Point3d.new(x1, y1, z1)
      p8 = Geom::Point3d.new(x0, y1, z1)

      [
        p1, p2, p2, p3, p3, p4, p4, p1,
        p5, p6, p6, p7, p7, p8, p8, p5,
        p1, p5, p2, p6, p3, p7, p4, p8
      ]
    end

    def open_dialog
      close_dialog

      @dialog = UI::HtmlDialog.new(
        dialog_title: "Параметри полиць",
        preferences_key: "ShelfCalculatorDialog",
        scrollable: true,
        resizable: true,
        width: 390,
        height: 560,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      html_path = File.join(File.dirname(__FILE__), "dialog.html")
      @dialog.set_file(html_path)

      @dialog.add_action_callback("ready") do |_ctx|
        send_init_data
      end

      @dialog.add_action_callback("update_params") do |_ctx, json_str|
        data = JSON.parse(json_str)
        @params[:thickness] = ShelfCalculator.parse_float(data["thickness"])
        @params[:num_items] = ShelfCalculator.parse_int(data["num_items"])
        @gaps_mm = Array(data["gaps"]).map { |g| ShelfCalculator.parse_float(g) }
        Sketchup.active_model.active_view.invalidate
      end

      @dialog.add_action_callback("apply") do |_ctx, json_str|
        data = JSON.parse(json_str)
        @params[:thickness] = ShelfCalculator.parse_float(data["thickness"])
        @params[:num_items] = ShelfCalculator.parse_int(data["num_items"])
        @gaps_mm = Array(data["gaps"]).map { |g| ShelfCalculator.parse_float(g) }

        if generate_shelves
          close_dialog
          Sketchup.active_model.select_tool(nil)
        end
      end

      @dialog.set_on_closed do
        @dialog = nil
        unless @generated
          Sketchup.active_model.select_tool(nil)
        end
      end

      @dialog.show
    end

    def send_init_data
      return unless @dialog
      payload = {
        axis: @selected_axis.to_s,
        axis_label: axis_label(@selected_axis),
        axis_length: axis_length_mm(@selected_axis).round(2),
        width: @dims_mm[:width].round(2),
        depth: @dims_mm[:depth].round(2),
        height: @dims_mm[:height].round(2),
        thickness: @params[:thickness],
        num_items: @params[:num_items],
        gaps: @gaps_mm
      }
      @dialog.execute_script("initDialog(#{payload.to_json});")
    end

    def close_dialog
      if @dialog
        dlg = @dialog
        @dialog = nil
        dlg.close
      end
    end

    def generate_shelves
      unless valid_layout?
        UI.messagebox("Перевірте розміри проміжків і товщину: сума перевищує розмір ніші або містить від'ємні значення.")
        return false
      end

      model = Sketchup.active_model
      entities = model.active_entities

      w_mm = @dims_mm[:width]
      d_mm = @dims_mm[:depth]
      h_mm = @dims_mm[:height]
      t_mm = @params[:thickness]
      n    = @params[:num_items]

      start_x = @bb.min.x
      start_y = @bb.min.y
      start_z = @bb.min.z

      model.start_operation("Створення полиць / перегородок", true)

      case @selected_axis
      when :z
        cursor_z = @gaps_mm[0]
        n.times do |i|
          shelf_group = entities.add_group
          shelf_group.name = "Полиця #{i + 1}"
          shelf_group.transformation = Geom::Transformation.translation([start_x, start_y, start_z + cursor_z.mm])

          face = shelf_group.entities.add_face([0, 0, 0], [w_mm.mm, 0, 0], [w_mm.mm, d_mm.mm, 0], [0, d_mm.mm, 0])
          face.reverse! if face.normal.z < 0
          face.pushpull(t_mm.mm)

          cursor_z += t_mm + @gaps_mm[i + 1]
        end

      when :x
        cursor_x = @gaps_mm[0]
        n.times do |i|
          part_group = entities.add_group
          part_group.name = "Перегородка #{i + 1}"
          part_group.transformation = Geom::Transformation.translation([start_x + cursor_x.mm, start_y, start_z])

          face = part_group.entities.add_face([0, 0, 0], [t_mm.mm, 0, 0], [t_mm.mm, d_mm.mm, 0], [0, d_mm.mm, 0])
          face.reverse! if face.normal.z < 0
          face.pushpull(h_mm.mm)

          cursor_x += t_mm + @gaps_mm[i + 1]
        end

      when :y
        cursor_y = @gaps_mm[0]
        n.times do |i|
          part_group = entities.add_group
          part_group.name = "Перегородка #{i + 1}"
          part_group.transformation = Geom::Transformation.translation([start_x, start_y + cursor_y.mm, start_z])

          face = part_group.entities.add_face([0, 0, 0], [w_mm.mm, 0, 0], [w_mm.mm, t_mm.mm, 0], [0, t_mm.mm, 0])
          face.reverse! if face.normal.z < 0
          face.pushpull(h_mm.mm)

          cursor_y += t_mm + @gaps_mm[i + 1]
        end
      end

      entities.erase_entities(@group) if @group && @group.valid?
      model.commit_operation
      @generated = true
      true
    end
  end

  def self.calculate
    model = Sketchup.active_model
    selection = model.selection

    if selection.length != 1 || !selection[0].is_a?(Sketchup::Group)
      UI.messagebox("Будь ласка, виділіть один бокс-нішу (групу) у проєкті.")
      return
    end

    bb = selection[0].bounds
    dims_mm = {
      width:  (bb.max.x - bb.min.x).to_mm.to_f,
      depth:  (bb.max.y - bb.min.y).to_mm.to_f,
      height: (bb.max.z - bb.min.z).to_mm.to_f
    }

    tool = ShelfEdgeTool.new(selection[0], dims_mm)
    model.select_tool(tool)
  end
end

unless file_loaded?(__FILE__)
  UI.menu("Extensions").add_item("Калькулятор полиць (3D)") { ShelfCalculator.calculate }
  UI.menu("Extensions").add_item("Калькулятор полиць: Перевірити оновлення") { ShelfCalculator.check_for_updates(silent: false) }

  cmd = UI::Command.new("Калькулятор полиць (3D)") { ShelfCalculator.calculate }
  cmd.tooltip = "Обрати ребро боксу та налаштувати полиці/перегородки"

  path = File.dirname(__FILE__)
  icon_16 = File.join(path, "images", "icon_16.png")
  icon_24 = File.join(path, "images", "icon_24.png")
  cmd.small_icon = icon_16 if File.exist?(icon_16)
  cmd.large_icon = icon_24 if File.exist?(icon_24)

  toolbar = UI::Toolbar.new("Калькулятор полиць")
  toolbar.add_item(cmd)
  toolbar.restore

  UI.start_timer(2.0, false) { ShelfCalculator.check_for_updates(silent: true) }

  file_loaded(__FILE__)
end
